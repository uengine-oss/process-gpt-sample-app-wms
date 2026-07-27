# 고속 분류 제어 계약

## Purpose

`SORTER`/`CONVEYOR` 설비에 대해 화물 간격(Carton Gapping), 속도 범위, 센서
감지 윈도우 같은 튜닝 가능한 분류 프로파일을 관리하고, `wms_wcs-equipment-control`의
표준 명령 봉투 위에서 Divert(슈트 라우팅)와 속도 조정(고정값 지정 또는 자동
모드 위임) 명령의 구조화된 `payload` 계약을 정의하며, 분류 결과(성공/오분류/잼)를
명령 결과 보고와 정합성 있게 연결하고 잼 발생 시 자동으로 설비 장애를
승격시키는 소프트웨어 계약을 정의한다. 이 계약은 실제 컨베이어 모터·센서를
구동하지 않는다 — 설비 등록, 명령 디스패치·취소, 상태·장애 상태 기계는
`wms_wcs-equipment-control`이 정의한 그대로이며, 이 계약은 그 위에 `SORTER`/
`CONVEYOR` 전용 설정과 명령 payload 규약만 얹는다.

## ADDED Requirements

### Requirement: 분류 설비 프로파일 등록
시스템은 `SORTER` 또는 `CONVEYOR` 타입의 등록된 설비에 대해 분류 프로파일을 등록할 수 있어야 한다(SHALL). 프로파일은 최소한 `min_carton_gap_mm`(최소 화물 간격), `speed_mode`(`FIXED` 또는 `AUTO`), `min_speed_value`/`max_speed_value`(속도 허용 범위), `speed_unit`, `sensor_detection_window_ms`(센서 감지 윈도우)를 가져야 한다(MUST). `SORTER`/`CONVEYOR`가 아닌 설비에는 프로파일을 등록할 수 없어야 한다(SHALL NOT). 설비당 프로파일은 하나만 존재할 수 있어야 한다(SHALL).

#### Scenario: SORTER 설비에 분류 프로파일을 등록한다
- **GIVEN** `equipment_type='SORTER'`인 설비 `SORTER-01`이 등록되어 있고 아직
  프로파일이 없다
- **WHEN** `min_carton_gap_mm=150`, `speed_mode='FIXED'`, `min_speed_value=0.5`,
  `max_speed_value=2.0`, `speed_unit='MPS'`, `sensor_detection_window_ms=80`으로
  프로파일 등록을 요청한다
- **THEN** `version=1`인 프로파일 레코드가 생성되고 `document_id`, `status`,
  `version`을 포함한 결과가 반환된다

#### Scenario: SORTER/CONVEYOR가 아닌 설비에는 프로파일을 등록할 수 없다
- **GIVEN** `equipment_type='AGV'`인 설비가 등록되어 있다
- **WHEN** 그 설비에 분류 프로파일 등록을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 프로파일이 생성되지 않는다

#### Scenario: 이미 프로파일이 있는 설비에는 중복 등록할 수 없다
- **GIVEN** 설비 `SORTER-01`에 이미 프로파일이 등록되어 있다
- **WHEN** 같은 설비에 프로파일 등록을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 창고 스코프가 없는 사용자는 프로파일을 등록할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고의 설비에 프로파일 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 분류 설비 프로파일 갱신
시스템은 기존 분류 프로파일의 값을 갱신할 수 있어야 한다(SHALL). 갱신은 프로파일의 `expected_version`을 검증해야 한다(MUST). 버전이 어긋나면 갱신하지 않고 `CONFLICT:` 오류를 반환해야 한다(SHALL).

#### Scenario: 프로파일의 속도 범위를 갱신한다
- **GIVEN** 프로파일이 `version=1`이고 `max_speed_value=2.0`이다
- **WHEN** `expected_version=1`로 `max_speed_value=2.5`로 갱신을 요청한다
- **THEN** 프로파일의 `max_speed_value`가 `2.5`로 바뀌고 `version`이 증가한다

#### Scenario: 버전이 어긋나면 갱신이 거부된다
- **GIVEN** 프로파일의 현재 `version=3`이다
- **WHEN** `expected_version=2`로 갱신을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 프로파일이 바뀌지 않는다

### Requirement: 분류 설비 프로파일 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 자신이 접근 가능한 창고의 설비별 분류 프로파일을 조회할 수 있어야 한다(SHALL).

#### Scenario: 창고 담당자가 설비의 분류 프로파일을 조회한다
- **GIVEN** 사용자가 창고 A에 대한 열람 권한을 가진다
- **WHEN** 창고 A의 설비 `SORTER-01`의 분류 프로파일 조회를 요청한다
- **THEN** `min_carton_gap_mm`, `speed_mode`, `min_speed_value`,
  `max_speed_value`, `speed_unit`, `sensor_detection_window_ms`,
  `status`, `version`을 포함한 프로파일이 반환된다

#### Scenario: 다른 창고의 설비 프로파일은 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 스코프가 있고 창고 B에는 스코프가 없다
- **WHEN** 창고 B의 설비 프로파일 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: Divert 명령 payload 계약
시스템은 `wms_wcs-equipment-control`의 명령 디스패치 계약을 통해 `SORTER`/`CONVEYOR` 설비에 `command_type='DIVERT'` 명령을 보낼 수 있어야 한다(SHALL). `DIVERT` 명령의 `payload`는 최소한 `target_chute`(목적 슈트 식별자)와 `item_identifier`(라우팅 대상 아이템 식별자)를 포함해야 한다(MUST). 대상 설비에 분류 프로파일이 등록되어 있지 않으면 `DIVERT` 명령을 디스패치할 수 없어야 한다(SHALL NOT).

#### Scenario: 프로파일이 있는 SORTER에 Divert 명령을 디스패치한다
- **GIVEN** 설비 `SORTER-01`이 `IDLE` 상태이고 분류 프로파일이 등록되어 있다
- **WHEN** `command_type='DIVERT'`, `payload={"target_chute":"CHUTE-12",
  "item_identifier":"BC-0001"}`로 명령을 디스패치한다
- **THEN** `PENDING` 상태의 명령 레코드가 생성된다

#### Scenario: target_chute 또는 item_identifier가 없으면 거부된다
- **GIVEN** 설비 `SORTER-01`에 분류 프로파일이 등록되어 있다
- **WHEN** `command_type='DIVERT'`, `payload={"target_chute":"CHUTE-12"}`(item_identifier 누락)로
  명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령이 생성되지 않는다

#### Scenario: 분류 프로파일이 없는 설비에는 Divert 명령을 보낼 수 없다
- **GIVEN** 설비 `SORTER-02`가 `IDLE` 상태이지만 분류 프로파일이 등록되어 있지
  않다
- **WHEN** 그 설비에 `command_type='DIVERT'` 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령이 생성되지 않는다

#### Scenario: CONVEYOR/SORTER가 아닌 설비에는 Divert 명령을 보낼 수 없다
- **GIVEN** 설비 `AGV-07`(`equipment_type='AGV'`)이 `IDLE` 상태다
- **WHEN** 그 설비에 `command_type='DIVERT'` 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 속도 조정 명령 payload 계약과 프로파일 범위 검증
시스템은 `wms_wcs-equipment-control`의 명령 디스패치 계약을 통해 `SORTER`/`CONVEYOR` 설비에 `command_type='SET_SPEED'` 명령을 보낼 수 있어야 한다(SHALL). `SET_SPEED` 명령의 `payload`는 `speed_mode`(`FIXED` 또는 `AUTO`)와 `speed_unit`을 포함해야 한다(MUST). `speed_mode='FIXED'`이면 `payload`에 `speed_value`가 있어야 하며(MUST), 그 값은 대상 설비 분류 프로파일의 `min_speed_value`~`max_speed_value` 범위 안이어야 한다(SHALL). `speed_unit`은 프로파일의 `speed_unit`과 일치해야 한다(MUST). `speed_mode='AUTO'`이면 설비가 프로파일 범위 안에서 스스로 속도를 조절하도록 위임하는 지시로 취급되어야 한다(SHALL) — 이 계약은 실제 속도 결정 로직을 수행하지 않는다.

#### Scenario: 프로파일 범위 안의 고정 속도로 조정한다
- **GIVEN** 설비 `SORTER-01`의 분류 프로파일이 `min_speed_value=0.5`,
  `max_speed_value=2.0`, `speed_unit='MPS'`다
- **WHEN** `command_type='SET_SPEED'`, `payload={"speed_mode":"FIXED",
  "speed_value":1.8,"speed_unit":"MPS"}`로 명령을 디스패치한다
- **THEN** `PENDING` 상태의 명령 레코드가 생성된다

#### Scenario: 프로파일 범위를 벗어난 속도는 거부된다
- **GIVEN** 설비 `SORTER-01`의 분류 프로파일이 `max_speed_value=2.0`이다
- **WHEN** `command_type='SET_SPEED'`, `payload={"speed_mode":"FIXED",
  "speed_value":3.5,"speed_unit":"MPS"}`로 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령이 생성되지 않는다

#### Scenario: speed_unit이 프로파일과 다르면 거부된다
- **GIVEN** 설비 `SORTER-01`의 분류 프로파일의 `speed_unit='MPS'`다
- **WHEN** `command_type='SET_SPEED'`, `payload={"speed_mode":"FIXED",
  "speed_value":1.0,"speed_unit":"FPM"}`로 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: AUTO 모드로 속도 제어를 설비에 위임한다
- **GIVEN** 설비 `SORTER-01`에 분류 프로파일이 등록되어 있다
- **WHEN** `command_type='SET_SPEED'`, `payload={"speed_mode":"AUTO",
  "speed_unit":"MPS"}`로 명령을 디스패치한다
- **THEN** `speed_value` 없이도 `PENDING` 상태의 명령 레코드가 생성된다

### Requirement: 분류 결과 보고와 명령 상태 매핑
시스템은 `wms_wcs-equipment-control`의 "명령 결과 보고" 계약을 통해 `DIVERT` 명령의 처리 결과를 보고받을 때, 보고된 `detail.outcome`(`SUCCESS`, `MISROUTE`, `JAM` 중 하나)과 보고된 명령 상태의 정합성을 검증해야 한다(SHALL). `outcome='SUCCESS'`는 명령 상태가 `COMPLETED`일 때만 허용되어야 한다(SHALL). `outcome`이 `MISROUTE` 또는 `JAM`이면 명령 상태가 `FAILED`일 때만 허용되어야 한다(SHALL). 정합성이 맞지 않는 보고는 거부되어야 한다(SHALL NOT 반영).

#### Scenario: 성공 분류가 완료 상태로 보고된다
- **GIVEN** `DIVERT` 명령이 `IN_PROGRESS` 상태다
- **WHEN** `command_status='COMPLETED'`, `detail={"outcome":"SUCCESS",
  "actual_chute":"CHUTE-12"}`로 결과를 보고한다
- **THEN** 명령 상태가 `COMPLETED`로 바뀌고 이벤트가 기록된다

#### Scenario: 오분류가 실패 상태로 보고된다
- **GIVEN** `DIVERT` 명령이 `IN_PROGRESS` 상태다
- **WHEN** `command_status='FAILED'`, `detail={"outcome":"MISROUTE",
  "actual_chute":"CHUTE-08"}`로 결과를 보고한다
- **THEN** 명령 상태가 `FAILED`로 바뀌고, 설비 상태는 `FAULT`로 전환되지
  않는다

#### Scenario: outcome과 명령 상태가 어긋나면 거부된다
- **GIVEN** `DIVERT` 명령이 `IN_PROGRESS` 상태다
- **WHEN** `command_status='COMPLETED'`, `detail={"outcome":"MISROUTE"}`로
  (성공 상태인데 오분류 outcome) 결과 보고를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령 상태가 바뀌지 않는다

### Requirement: 잼(JAM) 결과의 자동 장애 승격
시스템은 `DIVERT` 명령의 결과가 `detail.outcome='JAM'`으로 보고되면, 별도의 수동 장애 신고 없이 그 명령을 실행한 설비에 대해 자동으로 장애를 발생시켜야 한다(SHALL) — `wms_wcs-equipment-control`의 "설비 장애 발생 처리" Requirement와 동일한 효과(설비 상태를 `FAULT`로 전환하고, 그 설비의 다른 미종결 명령도 함께 `FAILED`로 전환)를 가져야 한다(SHALL). `outcome='MISROUTE'`는 자동으로 장애를 발생시키지 않아야 한다(SHALL NOT).

#### Scenario: 잼이 보고되면 설비에 자동으로 장애가 발생한다
- **GIVEN** 설비 `SORTER-01`에 `DIVERT` 명령이 `IN_PROGRESS` 상태이고, 같은
  설비에 다른 `PENDING` 명령이 하나 더 있다
- **WHEN** 그 `DIVERT` 명령이 `command_status='FAILED'`,
  `detail={"outcome":"JAM","reason":"CARTON_STUCK"}`로 보고된다
- **THEN** 설비 상태가 `FAULT`로 바뀌고, 그 `PENDING` 명령도 `FAILED`로
  전환되며, 새로 생성된 장애 레코드가 두 명령 모두와 연결된다

#### Scenario: 오분류는 설비 장애를 발생시키지 않는다
- **GIVEN** 설비 `SORTER-01`에 `DIVERT` 명령이 `IN_PROGRESS` 상태다
- **WHEN** 그 명령이 `command_status='FAILED'`, `detail={"outcome":"MISROUTE"}`로
  보고된다
- **THEN** 설비 상태는 `FAULT`로 바뀌지 않고 이전 상태(`RUNNING` 또는
  `IDLE`)를 유지한다

#### Scenario: 잼으로 발생한 장애는 기존 장애 해소 절차로 해소한다
- **GIVEN** 잼 보고로 설비 `SORTER-01`이 `FAULT` 상태가 되었다
- **WHEN** `WCS_OPERATOR`가 `resolution_note='카톤 제거 완료'`로 장애 해소를
  요청한다(`wms_wcs-equipment-control`의 기존 절차)
- **THEN** 장애 상태가 `RESOLVED`로, 설비 상태가 `IDLE`로 바뀐다

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 테이블(분류 프로파일)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·쓰기가 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT) — 기존 `wms_wcs-equipment-control` 및 그 이전 스펙과 동일한 RLS 패턴을 따른다.

#### Scenario: 다른 테넌트의 설비에는 분류 프로파일을 등록할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 설비에 분류 프로파일 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 허용되지 않은 역할은 프로파일을 갱신할 수 없다
- **GIVEN** 요청자가 `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` 중
  어느 것도 아니다
- **WHEN** 분류 프로파일 갱신을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 분류 프로파일 등록·갱신, Divert/속도 조정 명령의 payload 검증 거부, 잼으로 인한 자동 장애 승격을 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름 또는 자동 승격을 나타내는 식별자), `entity_type`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 프로파일 등록이 감사 이벤트를 남긴다
- **WHEN** 분류 프로파일이 성공적으로 등록된다
- **THEN** `wms.audit_events`에 `command='wms_create_sortation_profile'`,
  `entity_type='sortation_profile'`인 레코드가 생성된다

#### Scenario: 잼으로 인한 자동 장애 승격도 감사 이벤트를 남긴다
- **WHEN** `outcome='JAM'` 보고로 설비 장애가 자동 발생한다
- **THEN** `wms.audit_events`에 `entity_type='equipment_fault'`이고 `before`/`after`에
  설비 상태 변화(`RUNNING`/`IDLE` → `FAULT`)가 담긴 레코드가 생성된다
