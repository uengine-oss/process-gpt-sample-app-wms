## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.3, §3, Dematic iQ 세부 스펙)가
보여주듯, 실제 고속 분류 설비는 단순히 "명령을 보낸다"는 수준을 넘어 화물 간격
(Carton Gapping), 슈트 Divert, 부하별 자동 가변 속도 제어(Auto Speed Control)라는
분류기 고유의 세부 파라미터를 다룬다(Dematic iQ: "QNX RTOS 기반 고속 처리,
Carton Gapping, Scanning, Divert Control, Auto Speed Control"). 로봇 팔레타이징
셀의 "중량/용적 센서 레벨 미세 제어"도 같은 결의 세부 제어다.

직전 두 변경 `add-wcs-equipment-control-contract`(capability
`wms_wcs-equipment-control`, 아직 미구현)와 `add-wes-material-flow-control`
(capability `wms_wes-material-flow-control`, 아직 미구현)은 설비 등록, 명령
디스패치, 상태·이벤트 피드백, 장애 처리라는 **범용** 계약과, 그 위에서 WMS
작업 의도를 설비 명령으로 번역하는 미들웨어를 정의했다. `wms.equipment_commands`의
`command_type`/`payload`는 의도적으로 열린 집합(`add-wcs-equipment-control-contract`
design.md D7)이었고, 그 설계 문서는 이 변경을 정확히 예견했다: "`wms_wcs-sortation-logic`
(고속 분류 제어) | `equipment_type='SORTER'`에 대해 `command_type`을 확장(`DIVERT`,
`SET_SPEED`)하거나 `payload`에 Carton Gapping/속도 값을 담는다. 새 테이블 불필요"
(확장 지점 표). 그러나 그 표는 명령 확장만 언급했을 뿐, 실제 분류기가 노출하는
튜닝 가능한 설정값(최소 간격, 속도 모드, 속도 범위, 센서 감지 윈도우)을 어디에
저장할지는 다루지 않았다 — 이는 명령이 아니라 설비별 마스터데이터에 가깝다.

**정직한 전제 확인**: 이 변경이 확장하는 두 선행 변경(`add-wcs-equipment-control-contract`,
`add-wes-material-flow-control`) 모두 아직 구현되지 않았다. `supabase/migrations/`에
`wms.equipment`, `wms.equipment_commands` 등을 생성하는 마이그레이션 파일이
없다. 이 변경은 그 두 스펙(design.md에 남아 있는 검토용 스키마 후보)을 근거로
삼아 그 위에 이어 쓰는 스펙이며, 실제 DB에는 `wms_wcs-equipment-control`의
마이그레이션이 먼저 적용된 뒤에만 이 변경의 마이그레이션을 적용할 수 있다. 또한
이 저장소의 실제 스키마에는 handling unit(HU)/카톤 바코드 테이블이 없다 —
재고는 `wms.stock_ledger_entries.product_id`(SKU) 단위로만 추적되고, 실물
카톤 단위 스캔 식별자를 담을 곳이 없다. 이 변경은 그 공백을 감추지 않고,
Divert 대상 아이템 식별자를 참조 무결성 없는 범용 텍스트 필드로 설계한다(design.md
D6).

## What Changes

- `wms` 스키마(기존과 동일 schema/인스턴스, 동일 RLS/RPC 봉투 규약)에 분류 설비
  튜닝 설정을 위한 새 테이블 `wms.sortation_profiles`(설비별 최소 화물 간격,
  속도 모드/범위, 센서 감지 윈도우)를 추가한다. 신규 서비스나 신규 데이터베이스를
  만들지 않는다.
- `wms_wcs-equipment-control`이 소유한 `wms.equipment_commands.command_type`
  `CHECK` 제약을 확장하는 새 마이그레이션을 추가해 `DIVERT`, `SET_SPEED` 값을
  허용한다 — 그 테이블의 원 마이그레이션 파일 자체는 수정하지 않는다(그 스펙
  D7이 예견한 확장 방식).
- `wms.equipment_commands`에 `BEFORE INSERT` 트리거를 추가해, `equipment_type`이
  `SORTER`/`CONVEYOR`인 설비에 대한 `DIVERT`/`SET_SPEED` 명령의 `payload`가
  정해진 필드 구조를 갖추고 있는지, `SET_SPEED`의 목표 속도가 그 설비의
  `wms.sortation_profiles` 범위 안에 있는지 검증한다 — `wms_dispatch_equipment_command`
  RPC 자체는 수정하지 않는다.
- `wms.equipment_status_events`에 `AFTER INSERT` 트리거를 추가해, `DIVERT` 명령의
  결과 보고 `detail.outcome`이 `JAM`이면 자동으로 설비 장애를 발생시킨다(내부적으로
  `wms_wcs-equipment-control`의 `wms_raise_equipment_fault` 로직을 재사용해
  진행 중 명령 일괄 `FAILED` 처리까지 동일하게 적용) — `MISROUTE`는 자동 장애
  없이 해당 명령만 `FAILED`로 남긴다.
- 기존 RPC와 동일한 봉투(`tenant_id, warehouse_id, actor_id, idempotency_key,
  expected_version, correlation_id` 입력 / `{result, document_id, status,
  version, next_actions, warnings}` 출력, `CONFLICT:`/`FORBIDDEN:`/`INVALID:`
  접두 예외)를 따르는 새 RPC 3종을 추가한다: 분류 프로파일 등록, 분류 프로파일
  갱신, 분류 프로파일 조회. Divert/속도 조정 명령 자체는 새 RPC를 만들지 않고
  `wms_wcs-equipment-control`의 `wms_dispatch_equipment_command`를 그대로
  재사용한다(payload로 구분).
- `mcp/wms_mcp/mcp_server.py`에 위 3개 RPC를 감싸는 새 `@mcp.tool` 함수를
  추가한다. `DIVERT`/`SET_SPEED` 디스패치는 기존 `dispatch_equipment_command`
  도구를 그대로 쓴다(새 MCP 도구를 만들지 않음).
- 새 service role은 추가하지 않는다 — 프로파일 튜닝은 기존
  `WMS_ADMIN`/`WAREHOUSE_MANAGER`/`WCS_OPERATOR` 역할의 몫이다.
- 병목 감지·재라우팅 알고리즘(지능형 라우팅), 서열 적재 순서 계산(서열 출고),
  디지털 트윈 시뮬레이션 엔진, 실제 PLC 레벨 간격/속도 강제 실행은 이번
  변경에 포함하지 않는다 — 확장 지점만 남긴다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "고속 분류 제어
  (Sortation Logic)" 행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_wcs-sortation-logic`: `SORTER`/`CONVEYOR` 설비에 대해 화물 간격·속도
  범위·센서 감지 윈도우를 담은 분류 프로파일을 관리하고, `wms_wcs-equipment-control`의
  명령 봉투 위에 Divert(슈트 라우팅)와 속도 조정(고정/자동) 명령의 구조화된
  `payload` 계약을 정의하며, 분류 결과(성공/오분류/잼)를 명령 결과 보고에
  매핑하고 잼 발생 시 자동으로 설비 장애를 승격하는 계약.

### Modified Capabilities

(없음 — `wms_wcs-equipment-control`과 `wms_wes-material-flow-control`의 기존
Requirement를 변경하지 않는다. 두 스펙이 열어 둔 확장 지점(command_type 열린
집합, payload 자유 형식)만 채운다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 1종(`wms.sortation_profiles`), 신규 RPC
  3종, 신규 RLS 정책 추가. `wms_wcs-equipment-control`의
  `wms.equipment_commands`에 `command_type` `CHECK` 제약 확장과 `BEFORE INSERT`
  검증 트리거, `wms.equipment_status_events`에 `AFTER INSERT` 자동 장애 승격
  트리거를 얹는다(그 두 테이블은 이 변경이 아니라 선행 변경이 소유 — 배포
  순서 의존성이 생긴다, design.md 참고). 기존 `20260726_wms_core_schema.sql`의
  테이블/RPC는 변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 3종 추가. 기존 도구(설비
  명령 디스패치·결과 보고 포함)는 변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/wcs/sortation-profiles`(프로파일 관리 화면)가 추후 이 계약 위에 얹힐 수
  있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: 변경 없음(기존 `WMS_ADMIN`/`WAREHOUSE_MANAGER`/`WCS_OPERATOR`
  역할 재사용).
- **선행 의존성**: 이 변경은 `add-wcs-equipment-control-contract`(capability
  `wms_wcs-equipment-control`)가 정의하는 `wms.equipment`,
  `wms.equipment_commands`, `wms.equipment_status_events`,
  `wms_raise_equipment_fault`를 전제로 한다. 그 변경이 아직 구현되지 않았으므로,
  이 변경의 마이그레이션도 실제 DB에는 그 변경의 마이그레이션이 먼저 적용된
  뒤에만 적용할 수 있다. `add-wes-material-flow-control`과는 스키마 의존
  관계가 없다(업무 오더의 `command_payload`가 이 변경의 payload 계약을 그대로
  실어 나를 수 있다는 점에서만 자연스럽게 연결된다).
- **후속 영역**: 지능형 라우팅/병목 해소, 서열 출고/지능형 적재, 디지털
  트윈/시뮬레이션은 이 계약과 두 선행 계약을 함께 소비하는 별도 변경으로
  이후 진행한다(이번 변경에 포함하지 않음).
