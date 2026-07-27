## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.3, §3, 벤더별 세부 스펙)가 보여주듯,
실제 WMS/WCS 제품(SAP EWM 내장 MFS, Dematic iQ, Swisslog SynQ, 두산로지스틱스솔루션,
현대무벡스)은 예외 없이 자동화 설비(SRM, 컨베이어, 분류기, AGV/AMR, 로봇 적재 셀)를
소프트웨어에서 직접 제어하고, 설비 상태를 실시간으로 WMS에 피드백하며(두산: "고속
2-Way 피드백 루프"), 설비 이상 발생 시 실시간으로 감지·우회·복구한다(현대무벡스:
"시나리오 기반 실시간 우회 경로"). 그러나 이 샘플 앱은 현재 설비/자동화 개념이
전혀 없다 — `wms` 스키마에는 사람이 수행하는 문서 중심 작업(구매, 입고, 검수, 적치)만
존재하고, 그 작업을 실행할 자동화 설비를 등록·지시·모니터링할 계약이 없다.

동시에 main repo `openspec/changes/supabase-wms-erp-replacement/design.md` §3은
"자동창고 설비 PLC/WCS의 저수준 제어"를 명시적으로 1차 범위 밖에 둔다. 즉 이
샘플 앱이 실제 PLC/하드웨어를 구동할 필요는 없다 — 그러나 카탈로그가 보여주는
"WMS↔설비 간 명령·상태 계약" 자체는 소프트웨어 계약으로 스펙화할 수 있고, 이후
실제 WCS/PLC 게이트웨이든 소프트웨어 시뮬레이터든 이 계약만 채우면 동작하도록
설계할 수 있다.

이 변경은 다섯 개 후속 WCS/WES 영역(고속 분류 제어, 지능형 라우팅/병목 해소,
서열 출고/지능형 적재, 디지털 트윈/시뮬레이션, WES/MFS 자재 흐름 제어)의
**공통 기반**이 되는 첫 스펙이다. 설비 레지스트리, 명령 디스패치, 상태/이벤트
피드백, 장애 처리라는 최소 공통 계약을 여기서 확정해야 후속 다섯 영역이 별도
설비 개념을 새로 만들지 않고 이 계약 위에 각자의 도메인 로직(분류 속도 제어,
경로 재설정, 서열 적재 순서, 시뮬레이션, 미들웨어 라우팅)만 얹을 수 있다.

## What Changes

- `wms` 스키마(기존 `supabase/migrations/20260726_wms_core_schema.sql`과 동일
  schema, 동일 RLS/RPC 봉투 규약)에 자동화 설비 레지스트리, 명령 디스패치 로그,
  상태/이벤트 피드, 장애 기록을 위한 새 테이블을 추가한다. 신규 서비스나 신규
  데이터베이스를 만들지 않는다.
- 기존 명령 RPC와 동일한 봉투(`tenant_id, warehouse_id, actor_id, idempotency_key,
  expected_version, correlation_id` 입력 / `{result, document_id, status, version,
  next_actions, warnings}` 출력, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외)를
  따르는 새 RPC 세트를 추가한다: 설비 등록, 명령 디스패치, 명령 결과 보고, 설비
  상태 보고, 장애 발생, 장애 해소, 명령 취소, 상태 조회.
- `mcp/wms_mcp/mcp_server.py`에 위 RPC를 감싸는 새 `@mcp.tool` 함수들을 추가한다
  (기존 9개 도구와 같은 패턴).
- 설비 측(실제 PLC/WCS 게이트웨이 또는 소프트웨어 시뮬레이터)이 상태를 보고할 때
  쓰는 새 서비스 역할(`WCS_GATEWAY`)과, 사람이 모니터링·수동 명령·장애 해소를
  수행하는 새 역할(`WCS_OPERATOR`)을 `wms.memberships.role` 값 집합에 추가한다.
- 실제 PLC/하드웨어 구동, 고속 분류/라우팅/서열 적재/디지털 트윈 로직은 이번
  변경에 포함하지 않는다 — 확장 지점만 남긴다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "WCS 자동화 설비 직접
  제어"와 "실시간 모니터링/예외 복구" 두 행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_wcs-equipment-control`: 자동화 설비(SRM/컨베이어/분류기/AGV·AMR/로봇 셀)
  등록, 표준 명령 봉투를 통한 제어 명령 디스패치, 설비의 상태·이벤트 실시간
  피드백, 장애 발생 시 진행 중이던 명령의 처리와 복구 절차, 테넌트/창고 RLS
  스코핑과 감사 추적을 포함하는 WMS-WCS 소프트웨어 계약.

### Modified Capabilities

(없음 — 기존 스펙의 요구사항을 변경하지 않는다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 4종(`wms.equipment`, `wms.equipment_commands`,
  `wms.equipment_status_events`, `wms.equipment_faults`)과 신규 RPC 8종, 신규 RLS
  정책 추가. 기존 테이블/RPC는 변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 7~8종 추가 (읽기 전용 상태
  조회 포함). 기존 9개 도구는 변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/wcs/equipment`(레지스트리 관리), `/wcs/monitor`(실시간 상태·장애 모니터링)
  라우트가 추후 이 계약 위에 얹힐 수 있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: `WCS_OPERATOR`, `WCS_GATEWAY` 역할 추가. 기존 역할의 권한은
  변경하지 않는다.
- **후속 영역**: 고속 분류 제어, 지능형 라우팅/병목 해소, 서열 출고/지능형 적재,
  디지털 트윈/시뮬레이션, WES/MFS 자재 흐름 제어는 이 계약을 소비하는 별도
  변경으로 이후 진행한다(이번 변경에 포함하지 않음).
