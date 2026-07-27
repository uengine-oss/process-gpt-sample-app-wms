## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.3, §3, 현대무벡스 세부 스펙)가
보여주듯, 실제 WCS 제품 — 특히 현대무벡스 — 의 핵심 차별점은 "지능형 작업
할당"이다: **"설비 간 병목 현상(Bottleneck) 해소 알고리즘, 시간당 처리량
(Throughput) 최적화"**와 **"설비 이상 시 실시간 장비 상태 분석, 작업 경로
재설정 또는 우회 경로를 자동 할당"**. 이 두 문장은 정확히 두 가지 능력을
요구한다 — (1) 특정 설비/구역이 처리량 병목이 되고 있음을 감지하는 것, (2)
그 감지 결과를 이용해 신규 작업을 다른 설비로 우회시키는 것.

직전 두 변경이 이미 이 능력의 재료를 만들어 뒀다:

- `add-wcs-equipment-control-contract`(capability `wms_wcs-equipment-control`,
  아직 미구현)는 `wms.equipment`, `wms.equipment_commands`,
  `wms.equipment_status_events`, `wms.equipment_faults`라는 설비 상태·명령·
  이벤트·장애의 사실 기록을 정의했다.
- `add-wes-material-flow-control`(capability `wms_wes-material-flow-control`,
  아직 미구현)는 업무 오더를 설비에 디스패치할 때 "가용 설비 선택과 흐름
  균형" Requirement로 후보 설비를 고르는 로직을 정의했지만, 그 설계 문서
  D5는 스스로 이렇게 명시한다: **"이 설계의 부하 분산은 '미종결 명령이
  있으면 제외 + 최근 완료 건수가 적은 순'이라는 단순 규칙일 뿐이다... 후속
  '지능형 라우팅/병목 해소' 스펙이 실시간 처리량 관찰과 재라우팅을
  더한다."** 그 스펙의 확장 지점 표도 동일 문장으로 이 변경을 예견했다:
  "이 계약의 '가용 설비 선택' 단계를 대체하거나 앞단에 끼워 넣어(D5의 단순
  규칙 대신) 실시간 처리량 기반 재라우팅을 적용한다."

즉 이 변경은 area2가 의도적으로 비워 둔 자리를 채우는 세 번째 소비 스펙이다.
area1의 사실 기록(명령 큐, 장애 이력)을 관찰해 "지금 이 설비가 병목인가"를
임계값으로 판정하고, area2의 후보 선택 단계에 그 판정을 반영하며, 사람
운영자가 계획 정비 등을 이유로 특정 설비를 강제로 라우팅에서 제외할 수 있는
수동 개입 경로를 추가한다.

**정직한 전제 확인**: 이 변경이 근거로 삼는 두 선행 변경
(`add-wcs-equipment-control-contract`, `add-wes-material-flow-control`) 모두
아직 구현되지 않았다 — `supabase/migrations/`에 해당 마이그레이션 파일이
없고, `wms.equipment`, `wms.equipment_commands`, `wms.work_orders` 등은 현재
실행 중인 데이터베이스에 존재하지 않는다. 다만 아래에서 밝히듯 이 변경의
**DB 스키마 의존성은 area1에만 있다** — 이 변경이 새로 만드는 뷰와 함수는
area1의 테이블(설비, 명령, 장애)만 읽으며 area2의 `wms.work_orders`/
`wms.dispatch_waves`를 직접 참조하지 않는다. area2와의 연결은 "이 변경이
정의하는 후보 선택 함수를 area2의 디스패치 로직이 호출한다"는 **구현
통합 의존성**이며, 이는 DB 마이그레이션 순서와는 별개다(design.md 참고).

## What Changes

- `wms` 스키마(기존과 동일 schema/인스턴스, 동일 RLS/RPC 봉투 규약)에 병목
  감지 임계값 정책 테이블(`wms.wcs_routing_policies`)과 수동 라우팅 제외
  테이블(`wms.wcs_routing_overrides`)을 추가한다. 신규 서비스나 신규
  데이터베이스를 만들지 않는다.
- area1의 테이블(`wms.equipment_commands`, `wms.equipment_faults`)을 실시간
  집계하는 조회 전용 뷰 2개(`wms.wcs_equipment_load_snapshot`,
  `wms.wcs_equipment_bottleneck_status`)를 추가한다. 별도 집계 테이블이나
  트리거 기반 캐시는 만들지 않는다(design.md D1이 이유를 설명).
- area2의 "가용 설비 선택과 흐름 균형" Requirement가 수행하던 후보 선택
  로직의 **소유권을 이 계약으로 옮기는** 내부 함수
  `wms.wcs_select_available_equipment`를 추가한다. area2의 기존 후보 조건
  (설비 타입/구역 일치, `status='IDLE'`, 미종결 명령 없음)과 tie-break
  규칙(최근 완료 건수 최소)은 그대로 유지하면서, 그 앞뒤로 이 계약의 하드
  제외(강제 제외 목록)와 소프트 회피(병목 플래그)를 끼워 넣는다. area2의
  RPC 시그니처나 스펙 문구는 바꾸지 않는다 — 관찰 가능한 계약(입출력, 상태
  전이, 경고 코드)은 동일하게 유지된다(design.md 참고).
- 기존 RPC와 동일한 봉투(`tenant_id, warehouse_id, actor_id, idempotency_key,
  expected_version, correlation_id` 입력 / `{result, document_id, status,
  version, next_actions, warnings}` 출력, `CONFLICT:`/`FORBIDDEN:`/`INVALID:`
  접두 예외)를 따르는 새 RPC 5종을 추가한다: 병목 임계값 정책 등록, 정책
  갱신, 설비 강제 제외, 강제 제외 해제, 설비 라우팅 현황 조회.
- `mcp/wms_mcp/mcp_server.py`에 위 5개 RPC를 감싸는 새 `@mcp.tool` 함수를
  추가한다. 내부 후보 선택 함수(`wms.wcs_select_available_equipment`)는 MCP
  도구로 노출하지 않는다 — area2의 RPC 안에서만 호출된다.
- 새 service role은 추가하지 않는다 — 정책 관리와 강제 제외는 기존
  `WMS_ADMIN`/`WAREHOUSE_MANAGER`/`WCS_OPERATOR` 역할의 몫이다.
- 실제 설비 간 물리적 경로/토폴로지 재계산, 머신러닝 기반 예측, 서열
  출고/지능형 적재(area5), 디지털 트윈 시뮬레이션(area6)은 이번 변경에
  포함하지 않는다 — 확장 지점만 남긴다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "지능형 라우팅/병목
  해소" 행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_wcs-bottleneck-routing`: area1이 기록하는 설비 명령 큐·장애 이력을
  관찰해 임계값 기반으로 병목 설비를 판정하고, 그 판정을 area2의 가용 설비
  선택 로직에 반영해 신규 작업이 병목 설비를 회피하도록 하며, 운영자가
  특정 설비를 계획 정비 등의 이유로 자동 라우팅에서 수동으로 제외할 수 있게
  하는 계약.

### Modified Capabilities

(없음 — area2의 "가용 설비 선택과 흐름 균형" Requirement 문구와 시나리오는
그대로 유지된다. 그 Requirement가 정의한 후보 조건과 tie-break 규칙은 이
계약이 대체하는 것이 아니라 감싸는 것이다 — 강제 제외/병목 필터링을 통과한
후보 집합 안에서 area2의 기존 규칙이 그대로 적용된다. 따라서 area2의
스펙 문서 자체를 수정할 필요가 없다. area3(`wms_wcs-sortation-logic`)이
area1의 테이블에 트리거를 얹으면서도 area1의 스펙 문서를 수정하지 않은 것과
동일한 선례를 따른다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 2종(`wms.wcs_routing_policies`,
  `wms.wcs_routing_overrides`), 신규 뷰 2종(`wms.wcs_equipment_load_snapshot`,
  `wms.wcs_equipment_bottleneck_status`), 신규 내부 함수 1종
  (`wms.wcs_select_available_equipment`), 신규 RPC 5종, 신규 RLS 정책 추가.
  이 마이그레이션은 area1의 테이블에만 의존하며 area2의 테이블에는 의존하지
  않는다(Why 절 참고). 기존 `20260726_wms_core_schema.sql`의 테이블/RPC는
  변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 5종 추가. 기존 도구는
  변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/wcs/routing`(병목 현황·강제 제외 관리) 라우트가 추후 이 계약 위에 얹힐
  수 있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: 변경 없음(기존 역할 재사용).
- **통합 의존성**: `wms.wcs_select_available_equipment`가 실제로 신규 작업
  라우팅에 반영되려면, area2(`wms_wes-material-flow-control`)의 디스패치
  RPC 구현이 이 함수를 호출하도록 되어 있어야 한다 — 이는 DB 스키마
  의존성이 아니라 구현 통합 의존성이며, tasks.md에 별도 조정 작업으로
  남긴다.
- **후속 영역**: 서열 출고/지능형 적재(area5), 디지털 트윈/시뮬레이션
  (area6)은 이 계약과 area1/area2를 함께 소비하는 별도 변경으로 이후
  진행한다(이번 변경에 포함하지 않음).
