# 야드 및 도크 관리 계약

## Purpose

WMS가 창고별 도크(하역장)를 레지스트리로 관리하고, 입고 구매주문(PO)에 대해
특정 도크·특정 시간창의 예약(Dock Appointment)을 생성해 동일 도크의 겹치는
예약을 막고, 예약된 차량이 야드에 진입해 도킹(도크 점유)한 뒤 출차(도크 해제)
하는 흐름을 이산 상태 전이로 추적할 수 있도록 하는 소프트웨어 계약을 정의한다.
이 계약은 실시간 GPS/RTLS 기반 연속 위치 추적을 다루지 않으며, 기존
`wms_register_arrival`(입하 접수) RPC의 시그니처나 동작을 변경하지 않는다.

## ADDED Requirements

### Requirement: 도크 등록
시스템은 `WMS_ADMIN` 또는 `WAREHOUSE_MANAGER` 역할을 가진 사용자가 창고 스코프 안에서 도크를 레지스트리에 등록할 수 있어야 한다(SHALL). 도크는 최소한 `code`(창고 내 고유 식별자), `name`을 가져야 한다(MUST). 등록 직후 도크 상태는 `AVAILABLE`이어야 한다(SHALL).

#### Scenario: 신규 도크를 창고에 등록한다
- **GIVEN** `WMS_ADMIN` 역할을 가진 사용자가 대상 창고에 스코프를 가지고 있다
- **WHEN** `code='DOCK-01'`, `name='입고 하역장 1'`로 도크 등록을 요청한다
- **THEN** 상태 `AVAILABLE`, `version=1`인 도크 레코드가 생성되고 `document_id`,
  `status`, `version`을 포함한 결과가 반환된다

#### Scenario: 같은 창고에서 도크 코드를 중복 등록할 수 없다
- **GIVEN** 창고에 이미 `code='DOCK-01'`인 도크가 등록되어 있다
- **WHEN** 같은 창고에 동일한 `code='DOCK-01'`로 재등록을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 새 레코드는 생성되지 않는다

#### Scenario: 창고 스코프가 없는 사용자는 도크를 등록할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고에 도크 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 도크 정비 상태 전환
시스템은 `WMS_ADMIN` 또는 `WAREHOUSE_MANAGER` 역할을 가진 사용자가 도크를 `AVAILABLE`과 `CLOSED` 사이에서 수동으로 전환할 수 있어야 한다(SHALL). 도크 상태가 `OCCUPIED`인 동안에는 `CLOSED`로 전환할 수 없어야 한다(SHALL NOT) — 점유 중인 도크를 닫아 진행 중인 하역을 무효화하지 않기 위함이다.

#### Scenario: 관리자가 도크를 정비를 위해 닫는다
- **GIVEN** 도크 `DOCK-01`이 `AVAILABLE` 상태다
- **WHEN** `WMS_ADMIN`이 `new_status='CLOSED'`로 상태 전환을 요청한다
- **THEN** 도크 상태가 `CLOSED`로 바뀌고 `version`이 증가한다

#### Scenario: 점유 중인 도크는 닫을 수 없다
- **GIVEN** 도크 `DOCK-01`이 `OCCUPIED` 상태다
- **WHEN** `new_status='CLOSED'`로 상태 전환을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 도크 상태는 바뀌지 않는다

### Requirement: 도크 예약 생성
시스템은 `INBOUND_OPERATOR`, `WMS_ADMIN`, `PROCESS_AGENT` 역할을 가진 사용자가 입고 PO에 대해 특정 도크·특정 시간창(`scheduled_start`, `scheduled_end`)의 예약을 생성할 수 있어야 한다(SHALL). `appointment_type='INBOUND'`인 예약은 `po_id`를 필수로 가져야 한다(MUST). `scheduled_end`는 `scheduled_start`보다 이후여야 한다(MUST). 예약은 `SCHEDULED` 상태로 생성되어야 한다(SHALL). 대상 도크가 `CLOSED` 상태면 예약을 생성할 수 없어야 한다(SHALL NOT).

#### Scenario: 입고 PO에 대해 도크 예약을 생성한다
- **GIVEN** 도크 `DOCK-01`이 `AVAILABLE`이고, PO `po_id='PO-100'`가 존재한다
- **WHEN** `dock_id='DOCK-01'`, `po_id='PO-100'`, `scheduled_start='2026-08-01T09:00Z'`,
  `scheduled_end='2026-08-01T10:00Z'`로 예약 생성을 요청한다
- **THEN** `SCHEDULED` 상태의 새 예약 레코드가 생성되고 `document_id`, `status`,
  `version`을 포함한 결과가 반환된다

#### Scenario: 시간창이 뒤집힌 예약은 거부된다
- **WHEN** `scheduled_start='2026-08-01T10:00Z'`, `scheduled_end='2026-08-01T09:00Z'`로
  예약 생성을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 예약이 생성되지 않는다

#### Scenario: INBOUND 예약에 po_id가 없으면 거부된다
- **WHEN** `appointment_type='INBOUND'`이면서 `po_id`를 비운 채 예약 생성을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 닫힌 도크에는 예약을 만들 수 없다
- **GIVEN** 도크 `DOCK-01`이 `CLOSED` 상태다
- **WHEN** `DOCK-01`에 대해 예약 생성을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 도크 이중 예약 방지
시스템은 동일한 도크에 대해 진행 중(`SCHEDULED`, `CHECKED_IN`, `AT_DOCK`) 상태인 예약들의 시간창이 서로 겹치는 것을 허용하지 않아야 한다(SHALL NOT). 겹치는 시간창으로 예약을 생성하려는 요청은 거부되어야 한다(SHALL). 취소되었거나(`CANCELLED`) 이미 종료된(`DEPARTED`) 예약은 이 겹침 판정에서 제외되어야 한다(SHALL).

#### Scenario: 같은 도크의 겹치는 시간창 예약은 거부된다
- **GIVEN** 도크 `DOCK-01`에 `scheduled_start='09:00'`, `scheduled_end='10:00'`인
  `SCHEDULED` 예약이 이미 있다
- **WHEN** 같은 도크에 `scheduled_start='09:30'`, `scheduled_end='10:30'`으로
  새 예약 생성을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 새 예약은 생성되지 않는다

#### Scenario: 겹치지 않는 시간창은 같은 도크에 예약할 수 있다
- **GIVEN** 도크 `DOCK-01`에 `scheduled_start='09:00'`, `scheduled_end='10:00'`인
  `SCHEDULED` 예약이 있다
- **WHEN** 같은 도크에 `scheduled_start='10:00'`, `scheduled_end='11:00'`으로
  새 예약 생성을 요청한다
- **THEN** 겹치지 않으므로 새 예약이 `SCHEDULED` 상태로 생성된다

#### Scenario: 취소된 예약과 겹치는 시간창은 허용된다
- **GIVEN** 도크 `DOCK-01`에 `scheduled_start='09:00'`, `scheduled_end='10:00'`인
  예약이 `CANCELLED` 상태로 존재한다
- **WHEN** 같은 도크에 같은 시간창(`09:00`~`10:00`)으로 새 예약 생성을 요청한다
- **THEN** 취소된 예약은 겹침 판정에서 제외되므로 새 예약이 생성된다

### Requirement: 도크 예약 취소
시스템은 `INBOUND_OPERATOR`, `WMS_ADMIN`, `PROCESS_AGENT` 역할을 가진 사용자가 아직 도킹되지 않은(`SCHEDULED`, `CHECKED_IN`) 예약을 취소할 수 있어야 한다(SHALL). 이미 `AT_DOCK`, `DEPARTED`, `CANCELLED`로 종결된 예약은 취소할 수 없어야 한다(SHALL NOT).

#### Scenario: 예약 확정 전 예약을 취소한다
- **GIVEN** 예약이 `SCHEDULED` 상태다
- **WHEN** 올바른 `expected_version`으로 예약 취소를 요청한다
- **THEN** 예약 상태가 `CANCELLED`로 바뀐다

#### Scenario: 도킹이 끝난 예약은 취소할 수 없다
- **GIVEN** 예약이 이미 `AT_DOCK` 상태다
- **WHEN** 이 예약의 취소를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 차량 야드 체크인
시스템은 `INBOUND_OPERATOR` 또는 `WMS_ADMIN` 역할을 가진 사용자가 `SCHEDULED` 상태의 예약에 대해 차량이 야드에 도착했음을 체크인 처리할 수 있어야 한다(SHALL). 체크인은 도크를 아직 점유하지 않는다(SHALL NOT) — 차량이 야드에는 있지만 아직 도크에 접안하지 않은 상태를 의미한다. 체크인 시 `carrier_name`, `vehicle_plate_no`를 함께 기록할 수 있다(MAY).

#### Scenario: 예약된 차량이 야드에 도착해 체크인한다
- **GIVEN** 예약이 `SCHEDULED` 상태다
- **WHEN** `vehicle_plate_no='12가3456'`로 체크인을 요청한다
- **THEN** 예약 상태가 `CHECKED_IN`으로 바뀌고 도크 상태는 변경되지 않는다

#### Scenario: 이미 도킹된 예약은 다시 체크인할 수 없다
- **GIVEN** 예약이 `AT_DOCK` 상태다
- **WHEN** 체크인을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 차량 도킹 (도크 점유 시작)
시스템은 `CHECKED_IN` 상태의 예약을 `AT_DOCK`으로 전환하고, 대상 도크의 상태를 `OCCUPIED`로 변경할 수 있어야 한다(SHALL). 대상 도크가 이미 `OCCUPIED`이거나 `CLOSED`면 도킹을 거부해야 한다(SHALL).

#### Scenario: 체크인된 차량이 도크에 도킹한다
- **GIVEN** 예약이 `CHECKED_IN` 상태이고 대상 도크가 `AVAILABLE`이다
- **WHEN** 도킹을 요청한다
- **THEN** 예약 상태가 `AT_DOCK`으로, 도크 상태가 `OCCUPIED`로 바뀐다

#### Scenario: 이미 점유된 도크에는 도킹할 수 없다
- **GIVEN** 대상 도크가 다른 예약으로 이미 `OCCUPIED`다
- **WHEN** 이 예약으로 같은 도크에 도킹을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 예약·도크 상태는 바뀌지 않는다

### Requirement: 차량 출차 (도크 점유 해제)
시스템은 `AT_DOCK` 상태의 예약을 `DEPARTED`로 전환하고, 대상 도크의 상태를 `AVAILABLE`로 되돌릴 수 있어야 한다(SHALL) — 단, 그 사이 도크가 관리자에 의해 `CLOSED`로 전환되었다면 `AVAILABLE`로 되돌리지 않아야 한다(SHALL NOT).

#### Scenario: 도킹된 차량이 하역을 마치고 출차한다
- **GIVEN** 예약이 `AT_DOCK` 상태이고 대상 도크가 `OCCUPIED`다
- **WHEN** 출차를 요청한다
- **THEN** 예약 상태가 `DEPARTED`로, 도크 상태가 `AVAILABLE`로 바뀐다

#### Scenario: 도킹 전 상태에서는 출차 처리할 수 없다
- **GIVEN** 예약이 `SCHEDULED` 상태다
- **WHEN** 출차를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 도크 스케줄 조회
시스템은 창고 스코프를 가진 사용자가 특정 창고·기간의 도크별 예약 목록을 조회할 수 있어야 한다(SHALL). 조회 결과는 각 예약의 `dock_id`, `scheduled_start`, `scheduled_end`, `status`를 포함해야 한다(MUST) — 운영자가 겹치는 예약이 없는지 사전에 눈으로 확인할 수 있도록 한다.

#### Scenario: 창고 담당자가 하루치 도크 스케줄을 조회한다
- **GIVEN** 사용자가 창고 A에 대한 열람 권한을 가진다
- **WHEN** 창고 A의 `2026-08-01` 도크 스케줄 조회를 요청한다
- **THEN** 창고 A에 등록된 도크의 그 날짜 예약만 `dock_id`, `scheduled_start`,
  `scheduled_end`, `status`와 함께 반환된다

#### Scenario: 다른 창고의 도크 스케줄은 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 스코프가 있고 창고 B에는 스코프가 없다
- **WHEN** 창고 B의 도크 스케줄 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 기존 입하 접수(wms_register_arrival)와의 독립성
시스템은 도크 예약이 존재하지 않거나 어떤 상태이든 관계없이, 기존 `wms_register_arrival` 호출이 그대로 성립하도록 허용해야 한다(SHALL) — 이 계약은 `wms_register_arrival`의 전제조건이나 동작을 변경하지 않는다(SHALL NOT).

#### Scenario: 도크 예약 없이도 입하 접수는 그대로 동작한다
- **GIVEN** PO `po_id='PO-200'`에 대한 receipt가 `EXPECTED` 상태이고, 이 PO에
  연결된 도크 예약이 전혀 없다
- **WHEN** 기존과 동일하게 `wms_register_arrival(po_id='PO-200', ...)`을 호출한다
- **THEN** receipt 상태가 기존과 동일하게 `ARRIVED`로 바뀌고, 이 계약의 어떤
  테이블도 이 호출로 인해 자동으로 갱신되지 않는다

#### Scenario: 예약이 SCHEDULED 상태여도 입하 접수를 막지 않는다
- **GIVEN** PO `po_id='PO-300'`에 대한 도크 예약이 `SCHEDULED` 상태로 존재한다
- **WHEN** `wms_register_arrival(po_id='PO-300', ...)`을 호출한다
- **THEN** 예약이 `AT_DOCK`이 아니어도 `wms_register_arrival`은 정상적으로
  `ARRIVED` 전이를 수행한다

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 모든 테이블(도크, 도크 예약)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·명령이 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT) — 기존 `wms.purchase_orders`, `wms.equipment` 등과 동일한 RLS 패턴을 따른다.

#### Scenario: 다른 테넌트의 도크에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 도크에 예약 생성을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 창고 스코프가 없는 사용자는 예약을 조회할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고의 도크 예약 목록 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 도크 등록, 도크 정비 상태 전환, 도크 예약 생성, 도크 예약 취소, 차량 야드 체크인, 차량 도킹, 차량 출차를 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름), `entity_type`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 도크 예약 생성이 감사 이벤트를 남긴다
- **WHEN** 도크 예약이 성공적으로 생성된다
- **THEN** `wms.audit_events`에 `command='wms_schedule_dock_appointment'`,
  `entity_type='dock_appointment'`인 레코드가 생성된다

#### Scenario: 차량 도킹이 감사 이벤트를 남긴다
- **WHEN** 차량이 도킹 처리된다
- **THEN** `wms.audit_events`에 `command='wms_dock_vehicle'`,
  `entity_type='dock_appointment'`인 레코드가 생성되고 `before`에 `CHECKED_IN`
  상태, `after`에 `AT_DOCK` 상태가 담긴다
