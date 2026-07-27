## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.1, §4 Manhattan Active WM)가
정리한 "재고 관리 및 최적화" 영역의 세 번째 세부 기능은 **"SKU 출하 빈도 기반
슬롯팅(Slotting) 최적화"**다 — 자주 나가는 SKU를 접근성이 좋은 위치(포장/출하
근접, 낮은 선반 높이)로, 드물게 나가는 SKU를 접근성이 낮은 위치로 재배치해
피킹 동선을 줄이는 기능이다. Manhattan Active WM 절은 이 기능을 "WMS·Labor
Management·Slotting Optimization을 단일 터치 UI로 통합"한 것으로 소개해,
슬롯팅이 재고 마스터데이터·인력 관리와 나란히 놓이는 독립된 최적화 계층임을
보여준다. §5 표는 이 영역을 "SKU 출하 빈도 기반 위치 재배치 — `wms_master-data`의
위치 관리와는 다른 최적화 계층"이라고 미착수로 표시해 뒀다.

**정직한 전제 확인 1 — 위치/빈 모델이 아예 없다.** `supabase/migrations/20260726_wms_core_schema.sql`을
직접 확인한 결과, 이 저장소의 `wms` 스키마에는 `locations`/`bins` 테이블이
전혀 없다. 재고는 `wms.stock_ledger_entries`에 `(tenant_id, warehouse_id,
product_id, status)` 단위로만 기록되고(`status in ('RECEIVING','QC',
'AVAILABLE','SCRAP')`), 창고 내 어느 위치에 있는지는 어떤 테이블에도 남지
않는다. 따라서 "SKU를 어디로 재배치할 것인가"를 말할 수 있는 최소한의 위치
개념이 이 스펙 이전에는 존재하지 않는다.

**Option A/B 결정: Option A(최소 위치 모델을 이 스펙의 기반으로 신설)를
채택한다.** Option B(위치를 호출자가 주는 자유 텍스트 식별자로만 다루고
검증/최적화 계층만 스펙화)를 기각한 이유는 `add-wcs-sequential-dispatch`
design.md가 이미 같은 갈림길에서 Option A를 택하며 남긴 근거와 동일하다 —
"어딘가에 이미 존재하는 위치 식별자"를 전제로 Given 절을 쓰면, 그 전제를
실제로 만들 수단이 스펙 밖에 있으므로 E2E가 왕복 검증할 수 없는 참조가
된다. 슬롯팅은 본질적으로 "위치 A의 접근성이 위치 B보다 나쁘다"는 비교가
있어야 성립하는데, 자유 텍스트 위치 식별자에는 비교 가능한 속성이 전혀
없다. 다만 이 스펙이 신설하는 위치 모델은 **`wms_master-data`가 언젠가
가질 수 있는 전체 위치 계층(창고→구역→통로→선반→빈, 용량 관리 규칙,
위치-품목 적합성 규칙)을 대체하지 않는다** — 창고 코드, 구역 코드, 위치
코드, 접근성 순위(정수), 선택적 용량 수치만 가진 평평한 레지스트리로
스코프를 의도적으로 축소했다(design.md Non-Goals 참고).

**정직한 전제 확인 2 — 소비/출고로 인한 재고 차감 이력이 이 저장소에
아직 하나도 없다.** `wms_receive`, `wms._wms_finalize_disposition`을 직접
읽어 확인한 결과, 이 저장소에 현재 구현된 RPC는 `wms.stock_ledger_entries`에
**항상 양수 `qty_delta`만 기록한다** — 입고는 `QC` 상태에 `+qty`, 처분은
`QC`에서 `-received_qty`(같은 트랜잭션 안에서 상쇄)와 `AVAILABLE`/`SCRAP`에
`+received_qty`를 기록할 뿐, `AVAILABLE` 상태 재고를 소비 방향(음수)으로
차감하는 경로는 이 저장소에 **전혀 없다**. `add-wcs-sequential-dispatch`
(area5)가 정의한 `wms.outbound_orders`조차 그 design.md Non-Goals에서
"포장·출하 확정과 원장 차감... `wms.stock_ledger_entries`를 갱신하지
않는다"고 명시한다. 즉 이 저장소에는 "SKU가 얼마나 자주 나가는가"를 계산할
수 있는 실제 이력이 **오늘 시점에는 존재하지 않는다**. 이 스펙은 이 사실을
숨기거나 가짜 신호로 우회하지 않는다 — 속도(velocity) 계산 계약은 미래에
소비/출고 RPC가 `AVAILABLE` 상태에 음수 `qty_delta`를 기록하기 시작하는
순간부터 실제 신호를 만들어내도록 **전진(forward-looking) 설계**하고, 그런
이력이 없는 SKU는 조용히 기본 등급을 매기는 대신 분류 대상에서 명시적으로
제외해 그 사실을 응답에 남긴다(`skipped_no_data_count`). area5의
`wms.outbound_orders.status='COMPLETED'` 행을 보조 신호로 참조하는 방안도
검토했으나, 그 테이블도 아직 이 데이터베이스에 적용되지 않았고(area5도
"미구현" 상태) area5를 필수 의존성으로 만들면 "areas 1-8과 독립적으로
스펙화한다"는 이번 작업의 원칙에 어긋나므로, 이번 변경의 마이그레이션은
`wms.stock_ledger_entries`만 읽고 `wms.outbound_orders`에는 어떤 FK도
스키마 의존도 두지 않는다(design.md "확장 지점"에 향후 보조 신호로
문서화만 한다).

## What Changes

- `wms` 스키마(기존과 동일 schema·인스턴스, 동일 RLS/RPC 봉투 규약)에 5개
  신규 테이블을 추가한다: 보관 위치 레지스트리(`wms.storage_locations`),
  SKU-위치 현재 배정(`wms.sku_location_assignments`), 속도 등급별 목표
  접근성 정책(`wms.slotting_class_policies`), SKU별 출하 속도 스냅샷
  (`wms.sku_velocity_snapshots`), 재배치 추천(`wms.slotting_recommendations`).
  신규 서비스나 신규 데이터베이스를 만들지 않는다.
- `wms.stock_ledger_entries`만 읽는 조회 전용 계산 RPC
  (`wms_compute_sku_velocity`)를 추가한다 — 관찰 윈도우 안에서 `AVAILABLE`
  상태의 음수 `qty_delta`를 SKU별로 집계해 ABC 등급을 매기고, 그런 이력이
  없는 SKU는 등급 없이 명시적으로 건너뛴다.
- 위치 등록·활성화 관리, SKU-위치 배정 선언·재배정, 속도 등급 정책 등록·갱신,
  재배치 추천 생성, 추천 검토(승인/반려, HITL), 승인된 추천 적용까지 다루는
  새 RPC 10종을 기존과 동일한 봉투(`tenant_id, warehouse_id, actor_id,
  idempotency_key, expected_version, correlation_id` 입력 /
  `{result, document_id, status, version, next_actions, warnings?}` 출력,
  `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외)로 추가한다.
- 재배치 추천은 **사람이 검토·승인해야 적용되는 HITL 계약**이다(`wms_replenishment-planning`의
  RFQ 승인 패턴과 동일한 "보조적, 자율적이지 않음" 원칙). `WAREHOUSE_MANAGER`/
  `WMS_ADMIN`만 추천을 승인/반려할 수 있고, 승인 없이는 위치 배정이 바뀌지
  않는다.
- `mcp/wms_mcp/mcp_server.py`에 위 10개 RPC를 감싸는 `@mcp.tool` 함수를
  추가한다.
- 새 service role은 추가하지 않는다 — 기존 `WMS_ADMIN`/`WAREHOUSE_MANAGER`/
  `INBOUND_OPERATOR`/`PROCESS_AGENT` 역할을 재사용한다.
- 실제 이동 경로 최적화(동선 시뮬레이션), 용량 관리 규칙 엔진, 위치-품목
  적합성 규칙(위험물/온도대), area5의 `wms.outbound_orders`에 대한 스키마
  의존, 프론트엔드 화면 구현은 이번 변경에 포함하지 않는다 — 확장 지점만
  남긴다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "슬롯팅 최적화"
  행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_slotting-optimization`: `wms.stock_ledger_entries`의 `AVAILABLE`
  상태 소비 이력(오늘은 존재하지 않지만 미래에 기록되기 시작하면)으로부터
  SKU별 출하 속도 등급(ABC)을 계산하고, 이 스펙이 신설한 최소 위치
  레지스트리 위에서 현재 배정된 위치의 접근성과 속도 등급 사이의 괴리를
  찾아 재배치 추천을 생성하며, 사람 운영자의 승인을 거쳐야만 실제 배정이
  바뀌는 계약.

## Impact

- **DB**: `wms` 스키마에 신규 테이블 5종, 신규 뷰 1종
  (`wms.slotting_recommendation_overview_v`), 신규 RPC 10종, 신규 RLS
  정책 추가. 이 마이그레이션은 기존 `20260726_wms_core_schema.sql`의
  `wms.products`, `wms.warehouses`, `wms.stock_ledger_entries`,
  `wms.memberships`, `wms.has_role`, `wms.current_warehouse_ids`만 읽고,
  다른 어떤 area의 마이그레이션에도 의존하지 않는다(독립 영역). 기존
  테이블/RPC는 변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 10종 추가. 기존 도구는
  변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/inventory/slotting`(속도 등급·재배치 추천 대시보드) 라우트가 추후 이
  계약 위에 얹힐 수 있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: 변경 없음(기존 역할 재사용). 재배치 추천의 승인/반려는
  `WMS_ADMIN`/`WAREHOUSE_MANAGER`로 제한한다.
- **통합 의존성 없음**: 이 변경은 areas 1-8(WCS/WES, 야드/도크, 인력 관리
  포함) 어디에도 하드 의존하지 않는다. area5의 `wms.outbound_orders`는
  향후 보조 신호로 검토할 수 있는 확장 지점으로만 design.md에 남긴다.
