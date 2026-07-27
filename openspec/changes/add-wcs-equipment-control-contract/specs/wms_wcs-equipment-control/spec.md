# WCS 설비 제어 계약

## Purpose

WMS가 자동화 설비(스태커 크레인/SRM, 컨베이어, 분류기, AGV/AMR, 로봇 적재 셀)를
등록하고, 표준화된 명령 봉투로 제어 명령을 내리고, 설비로부터 상태·이벤트를
실시간으로 피드백받고, 장애 발생 시 진행 중이던 명령을 안전하게 처리·복구할 수
있도록 하는 소프트웨어 계약을 정의한다. 이 계약은 실제 PLC/하드웨어를 구동하지
않는다 — 계약을 실제로 채우는 쪽(진짜 WCS/PLC 게이트웨이 또는 소프트웨어
시뮬레이터)은 이 스펙이 정의하는 RPC/MCP 인터페이스만 준수하면 된다.

## ADDED Requirements

### Requirement: 자동화 설비 등록
시스템은 테넌트·창고 범위 안에서 자동화 설비를 레지스트리에 등록할 수 있어야 한다(SHALL). 설비는 최소한 `equipment_code`(창고 내 고유 식별자), `equipment_type`(`SRM`, `CONVEYOR`, `SORTER`, `AGV`, `AMR`, `ROBOT_CELL` 중 하나), `zone_code`(설비가 위치한 구역/로케이션 식별자)를 가져야 한다(MUST). 등록 직후 설비 상태는 `OFFLINE`이어야 한다(SHALL).

#### Scenario: 신규 설비를 창고에 등록한다
- **GIVEN** `WMS_ADMIN` 또는 `WAREHOUSE_MANAGER` 역할을 가진 사용자가 대상 창고에
  스코프를 가지고 있다
- **WHEN** `equipment_code='AGV-07'`, `equipment_type='AGV'`, `zone_code='ZONE-B'`로
  설비 등록을 요청한다
- **THEN** 상태 `OFFLINE`, `version=1`인 설비 레코드가 생성되고 `document_id`,
  `status`, `version`을 포함한 결과가 반환된다

#### Scenario: 같은 창고에서 설비 코드를 중복 등록할 수 없다
- **GIVEN** 창고에 이미 `equipment_code='AGV-07'`인 설비가 등록되어 있다
- **WHEN** 같은 창고에 동일한 `equipment_code='AGV-07'`로 재등록을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 새 레코드는 생성되지 않는다

#### Scenario: 창고 스코프가 없는 사용자는 설비를 등록할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고에 설비 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 설비 목록·상태 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 자신이 접근 가능한 창고의 설비 목록과 각 설비의 현재 상태, 최근 이벤트를 조회할 수 있어야 한다(SHALL). 조회 결과는 설비의 `equipment_type`, `zone_code`, `status`, `version`과, 해당 설비에 대해 진행 중인 명령이 있는지 여부를 포함해야 한다(MUST).

#### Scenario: 창고 담당자가 설비 현황을 조회한다
- **GIVEN** 사용자가 창고 A에 대한 열람 권한을 가진다
- **WHEN** 창고 A의 설비 상태 조회를 요청한다
- **THEN** 창고 A에 등록된 설비만 반환되고, 각 설비의 `status`, `version`,
  진행 중 명령 존재 여부가 포함된다

#### Scenario: 다른 창고의 설비는 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 스코프가 있고 창고 B에는 스코프가 없다
- **WHEN** 창고 B의 설비 상태 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 제어 명령 디스패치
시스템은 등록된 설비에 표준 명령 봉투(`tenant_id`, `warehouse_id`, `actor_id`, `idempotency_key`, `expected_version`, `correlation_id`)로 제어 명령을 보낼 수 있어야 한다(SHALL). 명령은 `command_type`(예: `MOVE`, `LOAD`, `UNLOAD`, `START`, `STOP`, `RESET`, `HOLD`, `RESUME`)과 명령별 세부 값을 담는 `payload`를 가져야 한다(MUST). 명령을 발행할 때 호출자가 알고 있던 설비 `version`(`expected_version`)이 설비의 현재 `version`과 다르면 명령을 생성하지 않고 `CONFLICT:` 오류를 반환해야 한다(SHALL). 명령은 `PENDING` 상태로 생성되어야 한다(SHALL). 명령은 발행 시 WMS 쪽 작업을 가리키는 `linked_entity_type`/`linked_entity_id`(예: 입고 receipt, 향후 적치·출고 작업)를 선택적으로 가질 수 있다(MAY).

#### Scenario: 가용한 설비에 명령을 디스패치한다
- **GIVEN** 설비 `AGV-07`이 `IDLE` 상태이고 `version=3`이다
- **WHEN** `expected_version=3`으로 `command_type='MOVE'`, `payload={"to_zone":"ZONE-C"}`
  명령을 디스패치한다
- **THEN** `PENDING` 상태의 새 명령 레코드가 생성되고 `document_id`, `status`,
  `next_actions`(예: `["report_command_result"]`)가 반환된다

#### Scenario: 버전이 어긋나면 명령이 거부된다
- **GIVEN** 설비 `AGV-07`의 현재 `version=4`이다
- **WHEN** `expected_version=3`으로 명령 디스패치를 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 명령 레코드가 생성되지 않는다

#### Scenario: 장애 상태 설비에는 새 명령을 보낼 수 없다
- **GIVEN** 설비 `AGV-07`의 상태가 `FAULT`다
- **WHEN** 이 설비에 새 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령이 생성되지 않는다

#### Scenario: 동일 idempotency_key 재시도는 중복 명령을 만들지 않는다
- **GIVEN** `idempotency_key='k-1'`로 명령이 이미 성공적으로 생성되었다
- **WHEN** 동일한 `idempotency_key='k-1'`로 같은 명령을 재요청한다
- **THEN** 새 명령이 생성되지 않고 최초 요청과 동일한 결과가 반환된다

### Requirement: 명령 결과 보고 (설비 → WMS 피드백)
시스템은 설비 측(실제 WCS/PLC 게이트웨이 또는 시뮬레이터)이 특정 명령의 처리 결과를 보고할 수 있어야 한다(SHALL). 보고 가능한 명령 상태는 `ACKNOWLEDGED`, `IN_PROGRESS`, `COMPLETED`, `FAILED`다(MUST). 명령이 `COMPLETED` 또는 `FAILED`로 보고되면 해당 설비 상태도 함께 갱신되어야 한다(SHALL) — 다른 진행 중 명령이 없으면 `IDLE`로, 있으면 `RUNNING`을 유지한다. 명령에 `linked_entity_type`/`linked_entity_id`가 있으면 결과 보고 시 해당 엔티티를 대상으로 한 감사 이벤트가 함께 기록되어야 한다(SHALL) — 다만 연결된 WMS 엔티티 자체의 상태를 이 계약이 직접 변경하지는 않는다(각 소비 스펙이 이 이벤트를 구독해 자신의 상태 전이를 결정한다).

#### Scenario: 설비가 명령 완료를 보고한다
- **GIVEN** 명령이 `IN_PROGRESS` 상태이고 `version=2`다
- **WHEN** `expected_version=2`로 `command_status='COMPLETED'` 보고가 들어온다
- **THEN** 명령 상태가 `COMPLETED`로 바뀌고 설비 상태가 다른 진행 중 명령이
  없으면 `IDLE`로 갱신되며, `wms.equipment_status_events`에 이벤트가 기록된다

#### Scenario: 설비가 명령 실패를 보고한다
- **GIVEN** 명령이 `IN_PROGRESS` 상태다
- **WHEN** `command_status='FAILED'`, `detail={"reason":"OBSTACLE_DETECTED"}` 보고가
  들어온다
- **THEN** 명령 상태가 `FAILED`로 바뀌고, 이벤트가 기록되며, 명령에
  `linked_entity_id`가 있으면 해당 엔티티를 대상으로 한 감사 이벤트도 함께
  기록된다

#### Scenario: 존재하지 않는 명령에 대한 결과 보고는 거부된다
- **WHEN** 존재하지 않는 `command_id`로 결과 보고를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 설비 상태 변경 보고
시스템은 설비 측이 특정 명령과 무관하게 자신의 상태 변화(예: 시동, 대기 전환, 오프라인 전환)를 직접 보고할 수 있어야 한다(SHALL). 이 보고는 설비의 `expected_version`을 검증해 낙관적 동시성을 지켜야 한다(MUST). 상태가 바뀔 때마다 `wms.equipment_status_events`에 이전 상태와 새 상태를 포함한 이벤트가 기록되어야 한다(SHALL).

#### Scenario: 설비가 기동해 대기 상태로 전환된다
- **GIVEN** 설비가 `OFFLINE`, `version=1`이다
- **WHEN** `expected_version=1`로 `new_status='IDLE'` 보고가 들어온다
- **THEN** 설비 상태가 `IDLE`로 바뀌고 `version`이 증가하며, 이전 상태
  `OFFLINE`과 새 상태 `IDLE`을 포함한 이벤트가 기록된다

#### Scenario: 정의되지 않은 상태 값은 거부된다
- **WHEN** `new_status='UNKNOWN_STATE'`로 상태 보고를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 설비 장애 발생 처리
시스템은 설비 장애를 기록할 수 있어야 한다(SHALL). 장애가 기록되면 해당 설비 상태는 `FAULT`로 전환되어야 한다(SHALL). 장애 발생 시점에 그 설비에 대해 `PENDING`, `ACKNOWLEDGED`, `IN_PROGRESS` 상태였던 모든 명령은 `FAILED`로 전환되고 장애 레코드와 연결되어야 한다(SHALL) — 이는 카탈로그의 "비상 장애 시나리오 기반 실시간 복구" 패턴과 일치한다. 장애는 `severity`(`WARNING`, `CRITICAL`, `BLOCKING` 중 하나)와 `fault_code`를 가져야 한다(MUST).

#### Scenario: 진행 중 명령이 있는 설비에서 장애가 발생한다
- **GIVEN** 설비 `SRM-02`에 `IN_PROGRESS` 명령이 1건 있다
- **WHEN** `fault_code='MOTOR_OVERHEAT'`, `severity='CRITICAL'`로 장애를 기록한다
- **THEN** 설비 상태가 `FAULT`로 바뀌고, 그 `IN_PROGRESS` 명령은 `FAILED`로
  전환되며 새로 생성된 장애 레코드의 `id`와 연결된다

#### Scenario: 장애 상태 설비는 신규 명령을 받지 못한다
- **GIVEN** 설비가 장애로 인해 `FAULT` 상태다
- **WHEN** 이 설비에 새 명령 디스패치를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다(위 "제어 명령 디스패치" 요구사항과 연결)

### Requirement: 설비 장애 해소
시스템은 `WCS_OPERATOR`, `WAREHOUSE_MANAGER`, `WMS_ADMIN` 역할의 사용자가 열려 있는 장애를 해소 처리할 수 있어야 한다(SHALL). 해소 시 해소 사유(`resolution_note`)를 필수로 받아야 한다(MUST). 해소되면 장애 상태는 `RESOLVED`로, 설비 상태는 `IDLE`로 전환되어야 한다(SHALL).

#### Scenario: 운영자가 장애를 해소하고 설비를 재가동 가능 상태로 되돌린다
- **GIVEN** 설비 `SRM-02`가 `FAULT` 상태이고 열린 장애 레코드가 있다
- **WHEN** `WCS_OPERATOR`가 `resolution_note='센서 교체 완료'`로 장애 해소를
  요청한다
- **THEN** 장애 상태가 `RESOLVED`로, 설비 상태가 `IDLE`로 바뀌고
  `resolved_by`, `resolved_at`이 기록된다

#### Scenario: 해소 사유 없이는 장애를 닫을 수 없다
- **WHEN** `resolution_note`를 비운 채 장애 해소를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: WCS_GATEWAY 역할은 장애를 해소할 수 없다
- **GIVEN** 요청자가 `WCS_GATEWAY` 서비스 아이덴티티다
- **WHEN** 장애 해소를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다 — 장애 해소는 사람의 확인을
  요구하는 판단이다

### Requirement: 명령 취소
시스템은 아직 종결되지 않은(`PENDING`, `ACKNOWLEDGED`, `IN_PROGRESS`) 명령을 취소할 수 있어야 한다(SHALL). 취소는 명령의 `expected_version`을 검증해야 한다(MUST). 이미 `COMPLETED`, `FAILED`, `CANCELLED`로 종결된 명령은 취소할 수 없어야 한다(SHALL NOT).

#### Scenario: 대기 중인 명령을 취소한다
- **GIVEN** 명령이 `PENDING` 상태다
- **WHEN** 올바른 `expected_version`으로 명령 취소를 요청한다
- **THEN** 명령 상태가 `CANCELLED`로 바뀐다

#### Scenario: 이미 완료된 명령은 취소할 수 없다
- **GIVEN** 명령이 이미 `COMPLETED` 상태다
- **WHEN** 이 명령의 취소를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 모든 테이블(설비, 명령, 상태 이벤트, 장애)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·명령이 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT) — 기존 `wms.purchase_orders`, `wms.receipts` 등과 동일한 RLS 패턴을 따른다.

#### Scenario: 다른 테넌트의 설비에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 설비에 명령 디스패치를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 역할이 없는 사용자는 상태 보고를 할 수 없다
- **GIVEN** 요청자가 `WCS_GATEWAY`도 `WMS_ADMIN`도 아니다
- **WHEN** 설비 상태 보고를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 설비 등록, 명령 디스패치, 명령 결과 보고, 설비 상태 보고, 장애 발생, 장애 해소, 명령 취소를 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름), `entity_type`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 명령 디스패치가 감사 이벤트를 남긴다
- **WHEN** 설비에 제어 명령이 성공적으로 디스패치된다
- **THEN** `wms.audit_events`에 `command='wms_dispatch_equipment_command'`,
  `entity_type='equipment_command'`인 레코드가 생성된다

#### Scenario: 장애 해소가 감사 이벤트를 남긴다
- **WHEN** 장애가 해소 처리된다
- **THEN** `wms.audit_events`에 `command='wms_resolve_equipment_fault'`,
  `entity_type='equipment_fault'`인 레코드가 생성되고 `before`에 `OPEN` 상태,
  `after`에 `RESOLVED` 상태가 담긴다
