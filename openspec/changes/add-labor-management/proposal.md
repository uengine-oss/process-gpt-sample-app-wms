## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.1 "인력 관리")는 실제 WMS 제품이
공통으로 다루는 네 가지 세부 기능을 "작업자별 생산성 측정, 필요 인력 수요
예측, 작업 가이던스, 게이미피케이션(Gamification)"으로 정리한다. Manhattan
Active WM 절은 여기서 한 걸음 더 나아가 "Labor Agent(인력 불균형 감지·재배치)"와
"WMS·Labor Management·Slotting Optimization을 단일 터치 UI로 통합"을 차별점으로
꼽는다.

그러나 이 샘플 앱의 `wms` 스키마(`supabase/migrations/20260726_wms_core_schema.sql`)에는
"작업(task)"이라는 개념 자체가 없다. 구매→입고→검수→적치 RPC 시퀀스가 유일한
"업무"이고, 그 실행은 각 RPC 호출의 `actor_id` 컬럼과 `wms.audit_events`
행으로만 귀속될 뿐 — "이 작업을 처리하는 데 얼마나 걸렸는가", "이 사람이 몇
건을 처리했는가"를 답할 수 있는 1급 데이터가 전혀 없다. main repo
`openspec/changes/supabase-wms-erp-replacement/specs/wms_warehouse-task-execution/spec.md`가
그리는 목표 모델(`CREATED → READY → CLAIMED → IN_PROGRESS → COMPLETED` 생명주기를
가진 범용 작업 큐, skill 기반 배정, SLA 관찰)은 이 저장소에 아직 없고, 이
변경의 범위도 아니다.

따라서 이 변경은 카탈로그의 네 기능을 이 샘플 앱의 실제 스코프에 맞게
축소·재정의한다: 범용 작업(task) 모델을 새로 만드는 대신, "작업자가 언제부터
언제까지 어떤 업무를 처리했는가"를 기록하는 최소 단위의 인력 활동 로그
(`wms.labor_activities`)를 신설하고, 그 위에 생산성 집계, 단순 비율 기반 인력
수요 추정, 경량 리더보드를 쌓는다. "작업 가이던스"는 기존 RPC들이 이미
반환하는 `next_actions` 필드가 사실상 담당하고 있으므로 이 변경에서 중복
구현하지 않는다.

이 영역은 area1~6(WCS/WES 체인)과 area7(야드/도크) 모두와 독립적이다 —
설비(equipment), 명령(command), 도크(dock) 개념을 전혀 참조하지 않고, 순수하게
"누가 얼마나 일했는가"라는 WMS 운영 측 도메인만 다룬다.

## What Changes

- `wms` 스키마(기존과 동일 schema, 동일 RLS/RPC 봉투 관례)에 인력 활동 로그
  테이블(`wms.labor_activities`)을 신설한다. 신규 서비스나 신규 데이터베이스를
  만들지 않는다.
- 작업자가 명시적으로 업무의 시작·완료를 알리는 RPC 쌍을 추가한다:
  `wms_start_labor_activity`, `wms_complete_labor_activity`,
  `wms_cancel_labor_activity`(중단). 기존 입고/검수/적치 RPC
  (`wms_register_arrival`, `wms_receive`, `wms_record_quality_result`,
  `wms_apply_disposition`, `wms_create_putaway_tasks`)의 시그니처나 동작은
  전혀 변경하지 않는다 — 새 RPC 쌍은 그 호출 앞뒤를 감싸는 독립적인
  계측(instrumentation) 계층이다(design.md D1).
- 생산성 집계 조회(작업자별·역할별·일자별 처리 건수, 평균 처리 시간, 처리
  수량), 단순 비율 기반 인력 수요 추정, 생산성 리더보드 조회를 위한 읽기
  전용 RPC를 추가한다: `wms_get_labor_productivity`, `wms_forecast_labor_demand`,
  `wms_get_labor_leaderboard`.
- 개인별 생산성 데이터에 대한 접근 통제 규칙을 정의한다 — 본인 데이터는
  누구나 조회할 수 있고, 교차 작업자 비교(리더보드·팀 생산성)는
  `WAREHOUSE_MANAGER`/`WMS_ADMIN`만 조회할 수 있다.
- `mcp/wms_mcp/mcp_server.py`에 위 RPC를 감싸는 새 `@mcp.tool` 함수들을
  추가한다(기존 도구와 같은 패턴).
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "인력 관리" 행을
  스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_labor-management`: 작업자가 업무 처리의 시작·완료·중단을 명시적으로
  기록하는 인력 활동 로그, 그 로그를 작업자별/역할별/일자별로 집계하는
  생산성 조회, 트레일링 N일 평균 처리량과 호출자가 제시한 예상 물량을 근거로
  한 단순 비율 기반 인력 수요 추정, 기간별 생산성 리더보드 조회, 그리고
  본인/관리자 구분의 접근 통제와 감사 추적을 포함하는 WMS 인력 관리 계약.

### Modified Capabilities

(없음 — 기존 스펙의 요구사항을 변경하지 않는다. 입고/검수/적치 RPC는 시그니처·
동작이 그대로 유지된다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 1종(`wms.labor_activities`), 신규 RPC
  6종(쓰기 3종 + 읽기 3종), 신규 RLS 정책 추가. 기존 테이블/RPC는 변경하지
  않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 6종 추가. 기존 도구는
  변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/labor/productivity`(개인·팀 생산성 대시보드) 라우트가 추후 이 계약 위에
  얹힐 수 있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: 새 역할을 추가하지 않는다 — 기존 `WMS_ADMIN`,
  `WAREHOUSE_MANAGER`(area1에서 이미 도입), `INBOUND_OPERATOR`,
  `QUALITY_INSPECTOR`, `PROCESS_AGENT` 역할을 재사용한다(design.md D4).
- **다른 영역과의 관계**: area1~7과 독립적이다 — 이 계약은 `wms.equipment`,
  `wms.equipment_commands`, `wms.docks` 등 어떤 설비/도크 개념도 참조하지
  않는다. main repo `wms_warehouse-task-execution`이 구상한 범용 작업 생명주기
  모델은 이 변경의 범위가 아니며(design.md 비고), 이 계약은 그 목표 모델로
  가는 첫 단계로서 "시간 계측"만 최소로 신설한다.
