# WES/MFS 자재 흐름 제어 계약

## Purpose

WMS 상위 지시(예: 입고 후 적치가 필요해진 상태)와 `wms_wcs-equipment-control`이
정의하는 설비 하부 동작 사이를 잇는 미들웨어 계약을 정의한다. 시스템은 WMS 쪽
작업 의도를 업무 오더(work order)로 등록하고, Wave(배치 큐잉 후 릴리즈) 또는
Waveless(즉시 디스패치) 전략에 따라 적합한 가용 설비를 선택해 표준 설비 명령으로
번역·디스패치하며, 설비 명령의 처리 결과를 구독해 업무 오더 자신의 상태로
되돌린다. 이 계약은 설비를 직접 제어하지 않는다 — 실제 명령 디스패치와 상태
피드백은 `wms_wcs-equipment-control`의 RPC를 통해서만 이루어진다. 이 계약은
또한 업무 오더가 참조하는 WMS 상위 엔티티(예: 입고 receipt) 자체의 상태를
직접 되돌리지 않는다 — 업무 오더 상태 변화를 관찰해 상위 엔티티의 다음 전이를
결정하는 것은 이 계약을 소비하는 오케스트레이션의 몫이다.

## ADDED Requirements

### Requirement: 업무 오더 등록
시스템은 WMS 쪽 작업 의도를 업무 오더로 등록할 수 있어야 한다(SHALL). 업무 오더는 최소한 `work_order_type`(예: `PUTAWAY`), 상위 WMS 작업을 가리키는 `linked_entity_type`/`linked_entity_id`(예: `'receipt'` + receipt id), 목표 설비 조건(`equipment_type`, `zone_code`), 디스패치할 명령 내용(`command_type`, `command_payload`), 디스패치 전략(`dispatch_mode`, `WAVE` 또는 `WAVELESS`)을 가져야 한다(MUST). `dispatch_mode='WAVELESS'`인 업무 오더는 등록 즉시 가용 설비 선택과 디스패치를 시도해야 한다(SHALL). `dispatch_mode='WAVE'`인 업무 오더는 지정된 웨이브에 속해야 하며(MUST), 그 웨이브가 릴리즈되기 전까지 `QUEUED` 상태를 유지해야 한다(SHALL).

#### Scenario: Waveless 업무 오더가 즉시 디스패치를 시도한다
- **GIVEN** `equipment_type='AGV'`, `zone_code='ZONE-B'` 조건에 맞는 `IDLE` 설비가
  있다
- **WHEN** `work_order_type='PUTAWAY'`, `linked_entity_type='receipt'`,
  `dispatch_mode='WAVELESS'`로 업무 오더를 등록한다
- **THEN** 업무 오더가 `DISPATCHED` 상태로 생성되고, 연결된 설비 명령의
  `document_id`를 포함한 결과가 반환된다

#### Scenario: Wave 업무 오더는 큐잉만 되고 즉시 디스패치되지 않는다
- **GIVEN** 개설된 `OPEN` 상태의 웨이브가 있다
- **WHEN** 그 웨이브를 지정해 `dispatch_mode='WAVE'`로 업무 오더를 등록한다
- **THEN** 업무 오더가 `QUEUED` 상태로 생성되고 설비 명령은 아직 디스패치되지
  않는다

#### Scenario: 릴리즈되었거나 존재하지 않는 웨이브를 지정할 수 없다
- **GIVEN** 웨이브가 이미 `RELEASED` 상태이거나 존재하지 않는다
- **WHEN** 그 웨이브를 지정해 `dispatch_mode='WAVE'` 업무 오더 등록을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 업무 오더가 생성되지 않는다

#### Scenario: 창고 스코프가 없는 사용자는 업무 오더를 등록할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고에 업무 오더 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 디스패치 웨이브 개설과 릴리즈
시스템은 창고 범위 안에서 `OPEN` 상태의 디스패치 웨이브를 개설할 수 있어야 한다(SHALL). 시스템은 `OPEN` 상태의 웨이브를 릴리즈할 수 있어야 한다(SHALL) — 릴리즈되면 웨이브 상태가 `RELEASED`로 바뀌고, 그 웨이브에 속한 `QUEUED` 업무 오더 전부에 대해 가용 설비 선택과 디스패치를 순차적으로 시도해야 한다(SHALL). 릴리즈는 웨이브의 `expected_version`을 검증해야 한다(MUST).

#### Scenario: 웨이브를 릴리즈하면 큐잉된 업무 오더가 일괄 디스패치를 시도한다
- **GIVEN** 웨이브에 `QUEUED` 업무 오더 3건이 속해 있고, 그중 2건은 조건에 맞는
  `IDLE` 설비가 있다
- **WHEN** 웨이브 릴리즈를 요청한다
- **THEN** 웨이브 상태가 `RELEASED`로 바뀌고, 조건이 맞는 2건은 `DISPATCHED`로,
  나머지 1건은 `QUEUED`로 남으며 결과에 가용 설비 부족 경고가 포함된다

#### Scenario: 이미 릴리즈된 웨이브는 다시 릴리즈할 수 없다
- **GIVEN** 웨이브가 이미 `RELEASED` 상태다
- **WHEN** 같은 웨이브의 릴리즈를 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 버전이 어긋나면 릴리즈가 거부된다
- **GIVEN** 웨이브의 현재 `version=2`이다
- **WHEN** `expected_version=1`로 릴리즈를 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 웨이브 상태가 바뀌지 않는다

### Requirement: 가용 설비 선택과 흐름 균형
시스템은 업무 오더를 디스패치할 때 업무 오더의 `equipment_type`, `zone_code`와 일치하고 `status='IDLE'`이며 미종결(`PENDING`/`ACKNOWLEDGED`/`IN_PROGRESS`) 명령이 없는 설비만 후보로 삼아야 한다(SHALL). 후보 설비가 둘 이상이면 최근 시간 창 안에서 `COMPLETED` 명령 수가 가장 적은 설비를 우선 선택해야 한다(SHOULD) — 이는 병목 예측이나 최적화 알고리즘이 아니라 단순 부하 분산이다. 조건에 맞는 후보 설비가 없으면 업무 오더는 `QUEUED` 상태를 유지해야 하며(SHALL), 응답에 가용 설비 부족을 알리는 경고가 포함되어야 한다(MUST).

#### Scenario: 후보가 하나뿐이면 그 설비로 디스패치한다
- **GIVEN** 조건에 맞는 `IDLE` 설비가 `AGV-07` 하나뿐이다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** `AGV-07`에 설비 명령이 디스패치되고 업무 오더가 `DISPATCHED`로
  바뀐다

#### Scenario: 후보가 여럿이면 최근 처리 건수가 적은 설비를 우선한다
- **GIVEN** 조건에 맞는 `IDLE` 설비가 `AGV-07`(최근 완료 명령 5건)과
  `AGV-08`(최근 완료 명령 1건) 둘이다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** `AGV-08`에 설비 명령이 디스패치된다

#### Scenario: 이미 미종결 명령이 있는 설비는 후보에서 제외된다
- **GIVEN** 조건에 맞는 설비가 `AGV-07` 하나뿐이고, 그 설비에는 이미
  `IN_PROGRESS` 명령이 있다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** 명령이 디스패치되지 않고 업무 오더가 `QUEUED` 상태를 유지하며
  결과에 가용 설비 부족 경고가 포함된다

#### Scenario: 조건에 맞는 설비가 전혀 없으면 큐잉 상태를 유지한다
- **GIVEN** 업무 오더의 `equipment_type='ROBOT_CELL'` 조건에 맞는 설비가 창고에
  등록되어 있지 않다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** 명령이 디스패치되지 않고 업무 오더가 `QUEUED` 상태를 유지하며
  결과에 가용 설비 부족 경고가 포함된다

### Requirement: 업무 오더 재디스패치 시도
시스템은 `QUEUED` 상태의 업무 오더에 대해 가용 설비 선택과 디스패치를 다시 시도할 수 있어야 한다(SHALL). 이미 `DISPATCHED`, `COMPLETED`, `FAILED`, `CANCELLED`로 전이된 업무 오더는 재디스패치할 수 없어야 한다(SHALL NOT).

#### Scenario: 가용 설비가 생긴 뒤 재디스패치가 성공한다
- **GIVEN** 업무 오더가 가용 설비 부족으로 `QUEUED` 상태이고, 이후 조건에 맞는
  설비가 `IDLE`로 전환되었다
- **WHEN** 그 업무 오더의 재디스패치를 요청한다
- **THEN** 업무 오더가 `DISPATCHED`로 바뀐다

#### Scenario: 이미 디스패치된 업무 오더는 재디스패치할 수 없다
- **GIVEN** 업무 오더가 이미 `DISPATCHED` 상태다
- **WHEN** 그 업무 오더의 재디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 설비 명령 결과의 업무 오더 반영
시스템은 업무 오더에 연결된 설비 명령이 `wms_wcs-equipment-control`의 "명령 결과 보고"를 통해 `COMPLETED` 또는 `FAILED`로 보고되면, 그 업무 오더의 상태를 함께 갱신해야 한다(SHALL) — `COMPLETED`는 업무 오더를 `COMPLETED`로, `FAILED`는 업무 오더를 `FAILED`로 전이시킨다. 이 반영은 업무 오더가 참조하는 상위 WMS 엔티티(예: `wms.receipts`) 자체의 상태는 변경하지 않아야 한다(SHALL NOT) — 상위 엔티티의 다음 전이를 결정하는 것은 이 계약을 소비하는 오케스트레이션의 책임이다.

#### Scenario: 설비 명령 완료가 업무 오더에 반영된다
- **GIVEN** 업무 오더가 `DISPATCHED` 상태이고 연결된 설비 명령이 `IN_PROGRESS`다
- **WHEN** 그 설비 명령이 `COMPLETED`로 보고된다
- **THEN** 업무 오더 상태가 `COMPLETED`로 바뀌고, 업무 오더가 참조하는
  `wms.receipts` 레코드의 상태는 이 계약에 의해 바뀌지 않는다

#### Scenario: 설비 명령 실패가 업무 오더에 반영된다
- **GIVEN** 업무 오더가 `DISPATCHED` 상태이고 연결된 설비 명령이 `IN_PROGRESS`다
- **WHEN** 그 설비 명령이 `FAILED`로 보고된다
- **THEN** 업무 오더 상태가 `FAILED`로 바뀐다

#### Scenario: 업무 오더와 무관한 설비 명령 결과는 영향을 주지 않는다
- **GIVEN** 설비 명령에 `linked_entity_type`이 `'work_order'`가 아니거나 비어
  있다
- **WHEN** 그 설비 명령이 `COMPLETED`로 보고된다
- **THEN** 어떤 업무 오더 레코드도 갱신되지 않는다

### Requirement: 업무 오더 취소
시스템은 아직 종결되지 않은(`QUEUED`, `DISPATCHED`) 업무 오더를 취소할 수 있어야 한다(SHALL). `DISPATCHED` 상태의 업무 오더를 취소하면 연결된 설비 명령도 함께 취소를 시도해야 한다(SHALL). 이미 `COMPLETED`, `FAILED`, `CANCELLED`로 종결된 업무 오더는 취소할 수 없어야 한다(SHALL NOT). 취소는 업무 오더의 `expected_version`을 검증해야 한다(MUST).

#### Scenario: 큐잉 중인 업무 오더를 취소한다
- **GIVEN** 업무 오더가 `QUEUED` 상태다
- **WHEN** 올바른 `expected_version`으로 취소를 요청한다
- **THEN** 업무 오더 상태가 `CANCELLED`로 바뀐다

#### Scenario: 디스패치된 업무 오더를 취소하면 연결된 설비 명령도 취소된다
- **GIVEN** 업무 오더가 `DISPATCHED` 상태이고 연결된 설비 명령이 `PENDING`이다
- **WHEN** 그 업무 오더의 취소를 요청한다
- **THEN** 업무 오더 상태가 `CANCELLED`로 바뀌고, 연결된 설비 명령도
  `CANCELLED`로 바뀐다

#### Scenario: 이미 완료된 업무 오더는 취소할 수 없다
- **GIVEN** 업무 오더가 이미 `COMPLETED` 상태다
- **WHEN** 그 업무 오더의 취소를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 업무 오더·웨이브 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 자신이 접근 가능한 창고의 업무 오더 목록·상태와 웨이브 현황을 조회할 수 있어야 한다(SHALL). 조회 결과는 업무 오더의 `status`, `dispatch_mode`, 연결된 설비 명령 존재 여부와 그 명령의 현재 상태를 포함해야 한다(MUST).

#### Scenario: 창고 담당자가 업무 오더 현황을 조회한다
- **GIVEN** 사용자가 창고 A에 대한 열람 권한을 가진다
- **WHEN** 창고 A의 업무 오더 조회를 요청한다
- **THEN** 창고 A에 등록된 업무 오더만 반환되고, 각 업무 오더의 `status`와
  연결된 설비 명령의 현재 상태가 포함된다

#### Scenario: 다른 창고의 업무 오더는 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 스코프가 있고 창고 B에는 스코프가 없다
- **WHEN** 창고 B의 업무 오더 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 모든 테이블(업무 오더, 디스패치 웨이브)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·명령이 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT) — 기존 `wms_wcs-equipment-control` 및 그 이전 스펙과 동일한 RLS 패턴을 따른다.

#### Scenario: 다른 테넌트의 업무 오더에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 업무 오더의 취소를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 허용되지 않은 역할은 업무 오더를 등록할 수 없다
- **GIVEN** 요청자가 `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`,
  `WMS_ADMIN` 중 어느 것도 아니다
- **WHEN** 업무 오더 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 웨이브 개설, 업무 오더 등록, 웨이브 릴리즈, 업무 오더 재디스패치, 업무 오더 취소를 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 설비 명령 결과가 업무 오더 상태로 자동 반영되는 경우에도 그 반영 자체가 감사 이벤트로 기록되어야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름 또는 자동 반영을 나타내는 식별자), `entity_type`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 업무 오더 등록이 감사 이벤트를 남긴다
- **WHEN** 업무 오더가 성공적으로 등록된다
- **THEN** `wms.audit_events`에 `command='wms_create_work_order'`,
  `entity_type='work_order'`인 레코드가 생성된다

#### Scenario: 설비 명령 결과의 자동 반영도 감사 이벤트를 남긴다
- **WHEN** 설비 명령 결과가 업무 오더 상태로 자동 반영된다
- **THEN** `wms.audit_events`에 `entity_type='work_order'`이고 `before`/`after`에
  업무 오더 상태 변화가 담긴 레코드가 생성된다
