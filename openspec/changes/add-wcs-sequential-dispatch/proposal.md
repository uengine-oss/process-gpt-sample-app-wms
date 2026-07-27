## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.3, §3, Dematic iQ·두산로지스틱스솔루션
세부 스펙)가 정리한 "서열 출고/지능형 적재"는 두 축으로 이루어진다 — (1) 매장
진열 순서 등 다운스트림 요구에 맞춰 출고 단위를 특정 순서로 내보내는 서열 출고
(Sequential Dispatch, 두산: "보관 위치별 정밀 재고 관리, 서열 출고 제어"), (2)
그 순서에 맞춰 여러 로봇 셀이 협업해 혼합 팔레트를 쌓고 중량/용적을 최적화하며
자동 스트레치 필름 포장과 연동하는 지능형 적재(Dematic iQ: "15개 로봇 셀 연동,
최대 28종 패키지 혼합 적재, Store-based 순서 적재, 중량/용적 최적화 및 자동
스트레치 필름 포장 연동").

**정직한 스코프 확인**: 이 기능은 본질적으로 출고(outbound) 측 기능이다 — "무엇을
순서대로 내보낼지"가 있어야 "서열"이 의미를 가진다. 그러나 이 저장소(`sample-app-wms`)의
실제 스키마(`supabase/migrations/20260726_wms_core_schema.sql`)에는 출고 관련
테이블이 전혀 없다 — `wms.purchase_orders`, `wms.receipts`, `wms.quality_inspections`,
`wms.inventory_dispositions`로 이어지는 입고 측 흐름만 구현되어 있다. main repo
`openspec/changes/supabase-wms-erp-replacement/specs/wms_outbound-fulfillment/spec.md`가
정의하는 목표 아키텍처(주문 접수 → FIFO/FEFO 할당·예약 → Wave/피킹 → 스캔 검증
피킹 → 포장·출하 확정 → 취소 복원, 총 6개 Requirement)는 이 저장소에 구현되지도,
스펙화되지도 않았다.

**Option A/B 결정: Option A를 선택한다.** 서열 출고는 "순서를 매길 대상"이 없으면
테스트 가능한 계약이 될 수 없다 — `linked_entity_type`/`linked_entity_id`만으로
opaque하게 참조를 남기는 Option B는 "출고 단위가 존재한다고 가정"하되 그 존재를
증명할 방법(생성 RPC, 상태, 시나리오)이 이 변경 안에 전혀 없어 스펙이 검증
불가능한 참조를 다루게 된다. 대신 이 변경은 main repo `wms_outbound-fulfillment`의
6개 Requirement 중 극히 일부(주문 접수의 최소 형태)만 떼어내 **명시적으로 훨씬
좁은 범위**로 재정의한다 — 재고 할당/예약(FIFO/FEFO), 피킹 작업·스캔 검증,
포장·출하 확정·원장 차감, 취소·복원은 전부 다루지 않는다(아래 "제외 범위" 및
design.md Non-Goals). 이렇게 좁힌 이유는 이 변경의 목적이 "출고 이행 전체"가
아니라 "서열/적재"이기 때문이다 — 재고를 얼마나 정확히 할당하는지가 아니라,
이미 확정된 출고 단위를 어떤 순서로 어떤 팔레트에 실을지가 이 변경의 핵심이다.

직전 네 변경이 이미 이 계약이 올라설 재료를 만들어 뒀다:

- `add-wcs-equipment-control-contract`(area1, capability `wms_wcs-equipment-control`,
  아직 미구현)는 설비 등록·명령 디스패치·상태 피드백·장애 처리라는 범용 계약을
  정의했다. 그 확장 지점 표는 이 변경을 정확히 예견했다: "`linked_entity_type='outbound_wave'`
  같은 새 값과, `payload`에 적재 순서 인덱스를 담아 `ROBOT_CELL` 대상 명령을
  디스패치한다."
- `add-wes-material-flow-control`(area2, capability `wms_wes-material-flow-control`,
  아직 미구현)는 `wms.dispatch_waves`(배치 큐잉·릴리즈)를 정의했다. 이 변경은
  그 Wave 개념을 그대로 재사용해 서열이 매겨진 출고 단위를 배치로 묶는다 —
  다만 area2의 `wms.work_orders`는 재사용하지 않는다(design.md D1이 이유를
  설명한다).
- `add-wcs-sortation-logic`(area3)은 area1의 `command_type` 열린 집합(D7)을
  확장하는 선례(새 `command_type` 추가 + payload 검증 트리거 + 결과 보고 outcome
  정합성 검증, 새 RPC 없이 기존 디스패치/보고 RPC 재사용)를 남겼다. 이 변경은
  `PALLETIZE`/`WRAP` command_type에 대해 동일한 패턴을 적용한다.
- `add-wcs-bottleneck-routing`(area4)은 area2의 "가용 설비 선택" 단계를 감싸는
  확장 지점(`wms.wcs_select_available_equipment`)을 만들었다. 이 변경은 그
  함수를 `ROBOT_CELL` 후보 선택에도 선택적으로 재사용할 수 있음을 확장 지점으로
  기록하되, 필수 의존성으로 삼지는 않는다.

**정직한 전제 확인**: 이 변경이 근거로 삼는 area1~4 전부 아직 구현되지 않았다 —
`supabase/migrations/`에 해당 마이그레이션 파일이 없다. 이 변경은 그 스펙들의
design.md에 남은 검토용 스키마 후보를 근거로 삼아 그 위에 이어 쓰는 스펙이다.
이 변경의 실제 DB 의존성은 **area1(필수)과 area2의 `wms.dispatch_waves`
테이블(필수)**이다 — area2의 `wms.work_orders`, area3, area4에는 스키마 의존성이
없다(design.md "정직한 전제 확인" 참고).

## What Changes

- `wms` 스키마(기존과 동일 schema/인스턴스, 동일 RLS/RPC 봉투 규약)에 최소 출고
  기반 테이블 1종(`wms.outbound_orders` — main repo `wms_outbound-fulfillment`
  대비 대폭 축소된, "제품·수량·매장/납기 서열 위치를 가진 출고 단위"만 담는
  플랫 테이블)과 서열 배정 테이블 1종(`wms.dispatch_sequences` — 출고 단위를
  area2의 `wms.dispatch_waves`에 묶고 `sequence_position`을 부여)을 추가한다.
  신규 서비스나 신규 데이터베이스를 만들지 않는다.
- `wms_wcs-equipment-control`(area1)이 소유한 `wms.equipment_commands.command_type`
  `CHECK` 제약을 확장하는 새 마이그레이션을 추가해 `PALLETIZE`, `WRAP` 값을
  허용한다 — 그 테이블의 원 마이그레이션 파일 자체는 수정하지 않는다(area1 D7,
  area3 D2가 예견한 확장 방식).
- `wms.equipment_commands`에 `BEFORE INSERT` 트리거를 추가해, `equipment_type='ROBOT_CELL'`
  설비에 대한 `PALLETIZE` 명령의 `payload`가 정해진 구조(서열 아이템 목록,
  각 아이템의 선언 중량/용적, 팔레트 단위 중량/용적 상한)를 갖추고 있는지 검증한다.
- `wms.equipment_status_events`에 `BEFORE INSERT` 트리거를 추가해, `PALLETIZE`
  결과 보고 `detail.outcome`(`SUCCESS`/`PARTIAL`/`OVERWEIGHT`/`OVERVOLUME`/`ABORTED`)과
  보고된 명령 상태의 정합성을 검증한다(area3 D4와 동일 패턴).
- `wms.equipment_status_events`에 `AFTER INSERT` 트리거를 추가해, `PALLETIZE`
  결과 보고의 `detail.loaded_items` 배열을 파싱해 각 항목이 가리키는
  `wms.dispatch_sequences` 행의 상태를 개별적으로 `COMPLETED`/`FAILED`로
  반영한다(area2의 완료 전파 트리거(D2)를 명령 단위가 아니라 항목 단위로
  일반화한 새 패턴).
- 기존 RPC와 동일한 봉투(`tenant_id, warehouse_id, actor_id, idempotency_key,
  expected_version, correlation_id` 입력 / `{result, document_id, status,
  version, next_actions, warnings}` 출력, `CONFLICT:`/`FORBIDDEN:`/`INVALID:`
  접두 예외)를 따르는 새 RPC 6종을 추가한다: 출고 단위 등록, 웨이브 내 서열
  배정, 서열 배정 취소, 혼합 팔레타이징 명령 디스패치, 서열/팔레트 현황 조회,
  팔레트 매니페스트 조회. `PALLETIZE`/`WRAP` 결과 보고 자체는 새 RPC를 만들지
  않고 area1의 `wms_report_command_result`를 그대로 사용한다(area3 선례).
- `mcp/wms_mcp/mcp_server.py`에 위 6개 RPC를 감싸는 새 `@mcp.tool` 함수를
  추가한다.
- 새 service role은 추가하지 않는다 — 기존 `WMS_ADMIN`/`WAREHOUSE_MANAGER`/
  `WCS_OPERATOR`/`PROCESS_AGENT`/`WCS_GATEWAY` 역할을 재사용한다.
- 재고 할당/예약(FIFO/FEFO), 피킹 작업·스캔 검증 피킹, 포장·출하 확정·원장
  차감, 출고 취소·복원(main repo `wms_outbound-fulfillment`의 나머지 5개
  Requirement), 서열 위치(`sequence_position`) 자체를 계산하는 최적화 알고리즘
  (매장 진열 순서 최적화, 병목 예측), 물리적 로봇 팔 협조 제어, 실제 스트레치
  필름 장비 프로토콜, 디지털 트윈/시뮬레이션(area6)은 이번 변경에 포함하지
  않는다 — 확장 지점만 남긴다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "서열 출고/지능형 적재"
  행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_wcs-sequential-dispatch`: 최소 범위의 출고 단위(`wms.outbound_orders`)를
  등록하고, area2의 디스패치 웨이브 안에서 매장/납기 순서에 따른
  `sequence_position`을 배정하며, area1의 명령 봉투 위에서 `ROBOT_CELL`
  설비를 대상으로 한 혼합 팔레타이징(`PALLETIZE`)과 스트레치 포장(`WRAP`)
  명령의 구조화된 `payload`·중량/용적 제약 계약을 정의하고, 팔레타이징
  결과(성공/부분 적재/중량 초과/용적 초과/중단)를 명령 결과 보고에 매핑해
  항목 단위로 서열 배정 상태를 되돌리는 계약.

### Modified Capabilities

(없음 — `wms_wcs-equipment-control`(area1), `wms_wes-material-flow-control`(area2)의
기존 Requirement를 변경하지 않는다. area1이 열어 둔 `command_type` 열린 집합과
`linked_entity_type` 느슨한 참조, area2가 제공하는 `wms.dispatch_waves`만
소비·확장한다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 2종(`wms.outbound_orders`,
  `wms.dispatch_sequences`), 신규 RPC 6종, 신규 RLS 정책 추가.
  `wms_wcs-equipment-control`(area1)의 `wms.equipment_commands`에
  `command_type` `CHECK` 제약 확장과 `BEFORE INSERT` 검증 트리거,
  `wms.equipment_status_events`에 `BEFORE INSERT` 정합성 검증 트리거와
  `AFTER INSERT` 항목 단위 완료 전파 트리거를 얹는다(그 두 테이블은 이
  변경이 아니라 area1이 소유 — 배포 순서 의존성이 생긴다, design.md 참고).
  기존 `20260726_wms_core_schema.sql`의 테이블/RPC는 변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 6종 추가. 기존 도구는
  변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/wcs/sequential-dispatch`(서열/팔레트 현황), `/wcs/pallet-manifest`(팔레트
  매니페스트 조회) 라우트가 추후 이 계약 위에 얹힐 수 있음을 design.md에
  확장 지점으로만 기록한다.
- **역할 모델**: 변경 없음(기존 역할 재사용).
- **선행 의존성**: 이 변경은 `add-wcs-equipment-control-contract`(area1,
  capability `wms_wcs-equipment-control`)의 `wms.equipment`,
  `wms.equipment_commands`, `wms.equipment_status_events`,
  `wms_dispatch_equipment_command`, `wms_report_command_result`와,
  `add-wes-material-flow-control`(area2, capability
  `wms_wes-material-flow-control`)의 `wms.dispatch_waves`를 전제로 한다. 두
  변경 모두 아직 구현되지 않았으므로, 이 변경의 마이그레이션도 실제 DB에는
  area1과 area2(`wms.dispatch_waves` 부분)의 마이그레이션이 먼저 적용된
  뒤에만 적용할 수 있다. `add-wes-material-flow-control`의
  `wms.work_orders`, `add-wcs-sortation-logic`(area3),
  `add-wcs-bottleneck-routing`(area4)에는 스키마 의존성이 없다(design.md
  참고).
- **제외 범위(명시적, main repo `wms_outbound-fulfillment` 대비 축소)**:
  재고 할당/예약(FIFO/FEFO), Wave 기반 피킹 작업 생성·스캔 검증 피킹, 포장·출하
  확정·원장 차감, 출고 취소/복원은 이 변경에 포함하지 않는다 — 이는 별도의
  향후 `wms_outbound-fulfillment` 스펙(미착수)의 몫이다. 이 변경의
  `wms.outbound_orders`는 그 미래 스펙이 등장하면 재사용되거나 대체될 수 있는
  최소 골격일 뿐이다.
- **후속 영역**: 디지털 트윈/시뮬레이션(area6)은 이 계약과 area1/area2를
  함께 소비하는 별도 변경으로 이후 진행한다(이번 변경에 포함하지 않음).
