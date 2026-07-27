# 서열 출고/지능형 적재 계약

## Purpose

최소 범위의 출고 단위를 등록하고, `wms_wes-material-flow-control`이 정의하는
디스패치 웨이브 안에서 매장/납기 순서에 따른 서열 위치(`sequence_position`)와
목표 팔레트(`target_pallet_code`)를 배정하며, `wms_wcs-equipment-control`의
표준 명령 봉투 위에서 `ROBOT_CELL` 설비를 대상으로 한 혼합 팔레타이징
(`PALLETIZE`)과 자동 스트레치 필름 포장(`WRAP`) 명령의 구조화된 `payload`
계약을 정의하며, 팔레타이징 결과(성공/부분 적재/중량 초과/용적 초과/중단)를
명령 결과 보고에 매핑해 항목 단위로 서열 배정 상태를 되돌리는 소프트웨어
계약을 정의한다. 이 계약은 실제 로봇 팔·스트레치 포장 장비를 구동하지 않는다
— 설비 등록, 명령 디스패치·취소, 상태·장애 상태 기계는
`wms_wcs-equipment-control`이 정의한 그대로이며, 이 계약은 그 위에 `ROBOT_CELL`
전용 서열/적재 설정과 명령 payload 규약만 얹는다. 이 계약은 재고 할당·예약,
피킹, 포장·출하 확정, 원장 차감을 다루지 않는다 — `wms.outbound_orders`는
그런 기능을 갖춘 정식 출고 이행 스펙이 아니라, 서열을 매길 수 있는 최소
골격이다.

## ADDED Requirements

### Requirement: 출고 단위 등록
시스템은 매장/배송처로 나갈 최소 범위의 출고 단위를 등록할 수 있어야 한다(SHALL). 출고 단위는 최소한 `store_code`(매장/배송처 식별자), `product_id`, `qty`를 가져야 한다(MUST). `declared_weight_kg`, `declared_volume_l`, `requested_delivery_date`는 선택 값으로 받을 수 있다(MAY). 등록 직후 상태는 `OPEN`이어야 한다(SHALL). 이 등록은 재고 가용성을 검증하거나 재고를 예약하지 않는다(SHALL NOT).

#### Scenario: 매장향 출고 단위를 등록한다
- **GIVEN** `WAREHOUSE_MANAGER` 역할을 가진 사용자가 대상 창고에 스코프를
  가지고 있다
- **WHEN** `store_code='STORE-042'`, `product_id`(등록된 상품), `qty=10`,
  `declared_weight_kg=4.2`, `declared_volume_l=3.1`로 출고 단위 등록을
  요청한다
- **THEN** 상태 `OPEN`, `version=1`인 출고 단위 레코드가 생성되고
  `document_id`, `status`, `version`을 포함한 결과가 반환된다

#### Scenario: 수량이 0 이하이면 등록이 거부된다
- **WHEN** `qty=0`으로 출고 단위 등록을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 레코드가 생성되지 않는다

#### Scenario: 창고 스코프가 없는 사용자는 출고 단위를 등록할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고에 출고 단위 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 디스패치 웨이브 내 서열 배정
시스템은 `OPEN` 상태의 출고 단위를 `wms_wes-material-flow-control`의 `OPEN` 상태 디스패치 웨이브 안에서 `sequence_position`(서열 위치)과 `target_pallet_code`(목표 팔레트 그룹)로 배정할 수 있어야 한다(SHALL). 같은 웨이브 안에서 `sequence_position`은 유일해야 한다(MUST). 배정이 성공하면 출고 단위 상태는 `SEQUENCED`로 전이해야 한다(SHALL). 배정은 출고 단위의 `expected_version`을 검증해야 한다(MUST).

#### Scenario: 웨이브 안에 서열 위치를 배정한다
- **GIVEN** 출고 단위가 `OPEN` 상태이고 웨이브가 `OPEN` 상태다
- **WHEN** `wave_id`, `sequence_position=1`, `target_pallet_code='PLT-0001'`로
  서열 배정을 요청한다
- **THEN** `QUEUED` 상태의 서열 배정 레코드가 생성되고 출고 단위 상태가
  `SEQUENCED`로 바뀐다

#### Scenario: 같은 웨이브에 같은 서열 위치를 중복 배정할 수 없다
- **GIVEN** 웨이브에 이미 `sequence_position=1`인 서열 배정이 있다
- **WHEN** 같은 웨이브에 `sequence_position=1`로 다른 출고 단위의 서열
  배정을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 새 레코드가 생성되지 않는다

#### Scenario: 릴리즈된 웨이브에는 서열을 배정할 수 없다
- **GIVEN** 웨이브가 이미 `RELEASED` 상태다
- **WHEN** 그 웨이브를 지정해 서열 배정을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 버전이 어긋나면 서열 배정이 거부된다
- **GIVEN** 출고 단위의 현재 `version=2`다
- **WHEN** `expected_version=1`로 서열 배정을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 서열 배정 레코드가 생성되지
  않는다

### Requirement: 서열 배정 취소
시스템은 아직 종결되지 않은(`QUEUED`, `DISPATCHED`) 서열 배정을 취소할 수 있어야 한다(SHALL). `DISPATCHED` 상태의 서열 배정을 취소하면 연결된 설비 명령도 함께 취소를 시도해야 한다(SHALL). 취소는 서열 배정의 `expected_version`을 검증해야 한다(MUST). 이미 `COMPLETED`, `FAILED`, `CANCELLED`로 종결된 서열 배정은 취소할 수 없어야 한다(SHALL NOT).

#### Scenario: 큐잉 중인 서열 배정을 취소한다
- **GIVEN** 서열 배정이 `QUEUED` 상태다
- **WHEN** 올바른 `expected_version`으로 취소를 요청한다
- **THEN** 서열 배정 상태가 `CANCELLED`로 바뀐다

#### Scenario: 디스패치된 서열 배정을 취소하면 연결된 설비 명령도 취소된다
- **GIVEN** 서열 배정이 `DISPATCHED` 상태이고 연결된 `PALLETIZE` 명령이
  `PENDING`이다
- **WHEN** 그 서열 배정의 취소를 요청한다
- **THEN** 서열 배정 상태가 `CANCELLED`로 바뀌고, 연결된 설비 명령도
  `CANCELLED`로 바뀐다

#### Scenario: 이미 완료된 서열 배정은 취소할 수 없다
- **GIVEN** 서열 배정이 이미 `COMPLETED` 상태다
- **WHEN** 그 서열 배정의 취소를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 혼합 팔레타이징 명령 디스패치
시스템은 `wms_wcs-equipment-control`의 명령 디스패치 계약을 통해 `ROBOT_CELL` 설비에 `command_type='PALLETIZE'` 명령을 보낼 수 있어야 한다(SHALL). 이 명령은 지정된 `wave_id`와 `target_pallet_code`를 공유하는 `QUEUED` 상태의 서열 배정 전부를 `sequence_position` 오름차순으로 정렬한 배열(`payload.sequence_items`)로 실어야 한다(MUST). `payload`에 `max_weight_kg` 또는 `max_volume_l`이 지정되면, 대상 서열 배정들의 `declared_weight_kg`/`declared_volume_l` 합계가 그 상한을 넘을 때 명령이 디스패치되지 않아야 한다(SHALL). 디스패치가 성공하면 대상 서열 배정 전부가 `DISPATCHED` 상태로 전이하고 같은 `equipment_command_id`로 연결되어야 한다(SHALL).

#### Scenario: 같은 팔레트로 묶인 서열 배정들을 하나의 명령으로 디스패치한다
- **GIVEN** 웨이브 `W-1`, `target_pallet_code='PLT-0001'`을 공유하는
  `QUEUED` 서열 배정이 `sequence_position` 1, 2 두 건 있고, 대상 설비
  `ROBOT-01`(`equipment_type='ROBOT_CELL'`)이 `IDLE` 상태다
- **WHEN** `equipment_id='ROBOT-01'`, `wave_id='W-1'`,
  `target_pallet_code='PLT-0001'`로 팔레타이징 명령 디스패치를 요청한다
- **THEN** `PENDING` 상태의 `PALLETIZE` 명령이 생성되고, `payload.sequence_items`에
  두 서열 배정이 `sequence_position` 순서대로 담기며, 두 서열 배정 모두
  `DISPATCHED` 상태로 바뀌고 같은 `equipment_command_id`를 갖는다

#### Scenario: 선언값 합계가 중량 상한을 넘으면 디스패치가 거부된다
- **GIVEN** `target_pallet_code='PLT-0002'`로 묶인 서열 배정들의
  `declared_weight_kg` 합계가 `260`이다
- **WHEN** `max_weight_kg=250`으로 팔레타이징 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령이 생성되지 않으며 대상
  서열 배정들의 상태가 바뀌지 않는다

#### Scenario: 대상 웨이브·팔레트에 QUEUED 서열 배정이 없으면 디스패치할 수 없다
- **GIVEN** `wave_id='W-1'`, `target_pallet_code='PLT-0003'`을 공유하는
  `QUEUED` 서열 배정이 없다
- **WHEN** 그 조합으로 팔레타이징 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: ROBOT_CELL이 아닌 설비에는 팔레타이징 명령을 보낼 수 없다
- **GIVEN** 설비 `AGV-07`(`equipment_type='AGV'`)이 `IDLE` 상태다
- **WHEN** 그 설비에 `command_type='PALLETIZE'` 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 스트레치 포장 명령 payload 계약
시스템은 `wms_wcs-equipment-control`의 명령 디스패치 계약을 통해 `ROBOT_CELL` 설비에 `command_type='WRAP'` 명령을 보낼 수 있어야 한다(SHALL). `WRAP` 명령의 `payload`는 최소한 `pallet_code`와 `wrap_program`(`STANDARD` 또는 `HEAVY`)을 포함해야 한다(MUST). 이 명령은 서열 배정의 상태를 변경하지 않는다(SHALL NOT).

#### Scenario: 완성된 팔레트에 스트레치 포장 명령을 디스패치한다
- **GIVEN** 설비 `ROBOT-01`이 `IDLE` 상태다
- **WHEN** `command_type='WRAP'`, `payload={"pallet_code":"PLT-0001",
  "wrap_program":"STANDARD"}`로 명령을 디스패치한다
- **THEN** `PENDING` 상태의 명령 레코드가 생성된다

#### Scenario: wrap_program이 없으면 거부된다
- **WHEN** `command_type='WRAP'`, `payload={"pallet_code":"PLT-0001"}`(wrap_program
  누락)로 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령이 생성되지 않는다

### Requirement: 팔레타이징 결과 보고와 항목 단위 상태 반영
시스템은 `wms_wcs-equipment-control`의 "명령 결과 보고" 계약을 통해 `PALLETIZE` 명령의 처리 결과를 보고받을 때, 보고된 `detail.outcome`(`SUCCESS`, `PARTIAL`, `OVERWEIGHT`, `OVERVOLUME`, `ABORTED` 중 하나)과 보고된 명령 상태의 정합성을 검증해야 한다(SHALL). `outcome`이 `SUCCESS` 또는 `PARTIAL`이면 명령 상태가 `COMPLETED`일 때만 허용되어야 한다(SHALL). 그 외 `outcome`이면 명령 상태가 `FAILED`일 때만 허용되어야 한다(SHALL). 보고가 정합성 검증을 통과하면, `detail.loaded_items` 배열의 각 원소가 가리키는 서열 배정 레코드를 `item_outcome`(`LOADED`는 `COMPLETED`로, `SKIPPED`는 `FAILED`로)에 따라 개별적으로 갱신해야 한다(SHALL).

#### Scenario: 전체 성공이 완료 상태로 보고되고 모든 항목이 COMPLETED로 반영된다
- **GIVEN** `PALLETIZE` 명령이 `IN_PROGRESS` 상태이고 `payload.sequence_items`에
  서열 배정 두 건이 담겨 있다
- **WHEN** `command_status='COMPLETED'`, `detail={"outcome":"SUCCESS",
  "loaded_items":[{"dispatch_sequence_id":"A","load_position":1,"item_outcome":"LOADED"},
  {"dispatch_sequence_id":"B","load_position":2,"item_outcome":"LOADED"}]}`로
  결과를 보고한다
- **THEN** 명령 상태가 `COMPLETED`로 바뀌고, 두 서열 배정 모두 `COMPLETED`
  상태와 각자의 `load_position`을 갖는다

#### Scenario: 부분 적재가 완료 상태로 보고되고 SKIPPED 항목만 FAILED로 반영된다
- **GIVEN** `PALLETIZE` 명령이 `IN_PROGRESS` 상태이고 서열 배정 두 건이
  담겨 있다
- **WHEN** `command_status='COMPLETED'`, `detail={"outcome":"PARTIAL",
  "loaded_items":[{"dispatch_sequence_id":"A","load_position":1,"item_outcome":"LOADED"},
  {"dispatch_sequence_id":"B","load_position":null,"item_outcome":"SKIPPED",
  "reason":"OVERWEIGHT"}]}`로 결과를 보고한다
- **THEN** 명령 상태가 `COMPLETED`로 바뀌고, 서열 배정 `A`는 `COMPLETED`로,
  서열 배정 `B`는 `FAILED`로 바뀐다

#### Scenario: 중량 초과가 실패 상태로 보고되면 관련 서열 배정 전부가 FAILED로 반영된다
- **GIVEN** `PALLETIZE` 명령이 `IN_PROGRESS` 상태다
- **WHEN** `command_status='FAILED'`, `detail={"outcome":"OVERWEIGHT",
  "loaded_items":[{"dispatch_sequence_id":"A","item_outcome":"SKIPPED"},
  {"dispatch_sequence_id":"B","item_outcome":"SKIPPED"}]}`로 결과를 보고한다
- **THEN** 명령 상태가 `FAILED`로 바뀌고, 두 서열 배정 모두 `FAILED`로
  바뀐다

#### Scenario: outcome과 명령 상태가 어긋나면 거부된다
- **GIVEN** `PALLETIZE` 명령이 `IN_PROGRESS` 상태다
- **WHEN** `command_status='COMPLETED'`, `detail={"outcome":"OVERWEIGHT", ...}`로
  (완료 상태인데 중량 초과 outcome) 결과 보고를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령 상태와 서열 배정 상태가
  바뀌지 않는다

### Requirement: 서열/팔레트 현황 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 자신이 접근 가능한 창고의 출고 단위·서열 배정 현황을 웨이브별, 팔레트별로 조회할 수 있어야 한다(SHALL). 조회 결과는 서열 배정의 `status`, `sequence_position`, `target_pallet_code`, 연결된 설비 명령 존재 여부와 그 명령의 현재 상태를 포함해야 한다(MUST).

#### Scenario: 창고 담당자가 웨이브의 서열 배정 현황을 조회한다
- **GIVEN** 사용자가 창고 A에 대한 열람 권한을 가진다
- **WHEN** 창고 A의 웨이브 `W-1`에 대한 서열 배정 조회를 요청한다
- **THEN** 그 웨이브에 속한 서열 배정만 `sequence_position` 순으로 반환되고,
  각 배정의 `status`와 연결된 설비 명령 상태가 포함된다

#### Scenario: 다른 창고의 서열 배정은 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 스코프가 있고 창고 B에는 스코프가 없다
- **WHEN** 창고 B의 서열 배정 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 팔레트 매니페스트 조회
시스템은 완료 또는 실패로 종결된 `PALLETIZE` 명령에 대해, 어떤 서열 배정이 어느 적재 위치(`load_position`)에 실렸는지 보여주는 팔레트 매니페스트를 조회할 수 있어야 한다(SHALL). 조회는 `equipment_command_id` 또는 `target_pallet_code`로 필터링할 수 있어야 한다(MUST).

#### Scenario: 완료된 팔레트의 매니페스트를 조회한다
- **GIVEN** `PALLETIZE` 명령이 `COMPLETED`로 종결되었고 결과에
  `loaded_items` 두 건이 보고되었다
- **WHEN** 그 명령의 `equipment_command_id`로 팔레트 매니페스트 조회를
  요청한다
- **THEN** 두 서열 배정의 `dispatch_sequence_id`, `load_position`,
  `item_outcome`이 포함된 매니페스트가 반환된다

#### Scenario: 아직 결과가 보고되지 않은 명령의 매니페스트는 비어 있다
- **GIVEN** `PALLETIZE` 명령이 아직 `IN_PROGRESS` 상태다
- **WHEN** 그 명령의 팔레트 매니페스트 조회를 요청한다
- **THEN** 빈 매니페스트가 반환된다(오류 아님)

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 모든 테이블(출고 단위, 서열 배정)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·쓰기가 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT) — 기존 `wms_wcs-equipment-control` 및 그 이전 스펙과 동일한 RLS 패턴을 따른다.

#### Scenario: 다른 테넌트의 출고 단위에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 출고 단위에 서열 배정을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 허용되지 않은 역할은 팔레타이징 명령을 디스패치할 수 없다
- **GIVEN** 요청자가 `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`,
  `WMS_ADMIN` 중 어느 것도 아니다
- **WHEN** 팔레타이징 명령 디스패치를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 출고 단위 등록, 서열 배정, 서열 배정 취소, 팔레타이징/포장 명령 디스패치 시도, 팔레타이징 결과의 항목 단위 자동 반영을 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름 또는 자동 반영을 나타내는 식별자), `entity_type`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 출고 단위 등록이 감사 이벤트를 남긴다
- **WHEN** 출고 단위가 성공적으로 등록된다
- **THEN** `wms.audit_events`에 `command='wms_create_outbound_order'`,
  `entity_type='outbound_order'`인 레코드가 생성된다

#### Scenario: 팔레타이징 결과의 항목 단위 자동 반영도 감사 이벤트를 남긴다
- **WHEN** `PALLETIZE` 결과가 서열 배정 상태로 자동 반영된다
- **THEN** `wms.audit_events`에 `entity_type='dispatch_sequence'`이고
  `before`/`after`에 서열 배정 상태 변화가 담긴 레코드가 생성된다
