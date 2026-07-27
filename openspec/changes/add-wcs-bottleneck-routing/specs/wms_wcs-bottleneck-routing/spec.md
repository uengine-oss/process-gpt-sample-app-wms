# 지능형 라우팅/병목 해소 계약

## Purpose

`wms_wcs-equipment-control`이 기록하는 설비 명령 큐와 장애 이력을 관찰해,
임계값 기반으로 특정 설비가 처리량 병목이 되고 있는지 실시간으로 판정하고,
`wms_wes-material-flow-control`이 신규 작업을 가용 설비에 디스패치할 때 그
판정을 반영해 병목 설비를 회피하도록 하며, 운영자가 계획 정비 등의 이유로
특정 설비를 병목 여부와 무관하게 자동 라우팅에서 수동으로 제외할 수 있는
소프트웨어 계약을 정의한다. 이 계약은 실제 설비 경로/토폴로지를 재계산하지
않으며, 머신러닝 기반 예측을 수행하지 않는다 — 큐 길이와 최근 장애 빈도라는
두 개의 설명 가능한 임계값 비교만 수행한다.

## ADDED Requirements

### Requirement: 설비 부하·건강 신호 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 자신이 접근 가능한 창고의 설비별 실시간 부하·건강 신호를 조회할 수 있어야 한다(SHALL). 조회 결과는 각 설비의 `queue_depth`(미종결 명령 수), `recent_fault_count`(최근 관찰 윈도우 내 장애 건수), `recent_completed_count`(최근 관찰 윈도우 내 완료 명령 수)를 포함해야 한다(MUST). 이 신호는 별도로 저장된 값이 아니라 조회 시점에 계산된 값이어야 한다(SHALL).

#### Scenario: 창고 담당자가 설비 부하 현황을 조회한다
- **GIVEN** 사용자가 창고 A에 대한 열람 권한을 가진다
- **WHEN** 창고 A의 설비 라우팅 현황 조회를 요청한다
- **THEN** 창고 A에 등록된 설비만 반환되고, 각 설비의 `queue_depth`,
  `recent_fault_count`, `recent_completed_count`가 포함된다

#### Scenario: 다른 창고의 설비 신호는 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 스코프가 있고 창고 B에는 스코프가 없다
- **WHEN** 창고 B의 설비 라우팅 현황 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 임계값 기반 병목 감지
시스템은 설비별로 `queue_depth`가 적용 가능한 큐 길이 임계값 이상이거나, 최근 관찰 윈도우 내 `recent_fault_count`가 적용 가능한 장애 건수 임계값 이상이면 그 설비를 병목으로 판정해야 한다(SHALL). 판정 결과는 `is_bottleneck` 여부와, 어느 조건 때문에 병목으로 판정되었는지를 나타내는 `bottleneck_reasons`를 포함해야 한다(MUST). 해당 창고·설비 유형에 등록된 정책이 없으면 시스템 기본 임계값이 적용되어야 한다(SHALL).

#### Scenario: 큐 길이가 임계값을 넘으면 병목으로 판정된다
- **GIVEN** 설비 `AGV-07`의 큐 길이 임계값이 `3`이고, 현재 미종결 명령이
  `4`건이다
- **WHEN** 설비 라우팅 현황을 조회한다
- **THEN** `AGV-07`의 `is_bottleneck=true`이고 `bottleneck_reasons`에
  `QUEUE_DEPTH_EXCEEDED`가 포함된다

#### Scenario: 최근 장애 건수가 임계값을 넘으면 병목으로 판정된다
- **GIVEN** 설비 `SRM-02`의 장애 건수 임계값이 `1`이고, 최근 관찰 윈도우
  안에 장애가 `2`건 발생했다
- **WHEN** 설비 라우팅 현황을 조회한다
- **THEN** `SRM-02`의 `is_bottleneck=true`이고 `bottleneck_reasons`에
  `FAULT_FREQUENCY_EXCEEDED`가 포함된다

#### Scenario: 두 지표 모두 임계값 미만이면 병목으로 판정되지 않는다
- **GIVEN** 설비의 큐 길이와 최근 장애 건수가 모두 적용 임계값 미만이다
- **WHEN** 설비 라우팅 현황을 조회한다
- **THEN** 그 설비의 `is_bottleneck=false`이고 `bottleneck_reasons`가
  비어 있다

#### Scenario: 정책이 없는 설비 유형에는 기본 임계값이 적용된다
- **GIVEN** 창고 A의 `SORTER` 유형에는 등록된 라우팅 정책이 없다
- **WHEN** 창고 A의 `SORTER` 설비 라우팅 현황을 조회한다
- **THEN** 시스템 기본 임계값 기준으로 병목 판정이 계산된다

### Requirement: 병목 감지 임계값 정책 관리
시스템은 창고·설비 유형 단위로 병목 감지 임계값 정책을 등록·갱신할 수 있어야 한다(SHALL). 정책은 최소한 `equipment_type`, `queue_depth_threshold`, `fault_count_threshold`를 가져야 한다(MUST). 동일한 창고·설비 유형 조합에는 정책이 하나만 존재할 수 있어야 한다(SHALL). 갱신은 정책의 `expected_version`을 검증해야 한다(MUST).

#### Scenario: 설비 유형별로 임계값 정책을 등록한다
- **GIVEN** 창고 A의 `AGV` 유형에는 아직 등록된 정책이 없다
- **WHEN** `equipment_type='AGV'`, `queue_depth_threshold=5`,
  `fault_count_threshold=2`로 정책 등록을 요청한다
- **THEN** `version=1`인 정책 레코드가 생성되고 `document_id`, `status`,
  `version`을 포함한 결과가 반환된다

#### Scenario: 같은 창고·설비 유형에 정책을 중복 등록할 수 없다
- **GIVEN** 창고 A의 `AGV` 유형에 이미 정책이 등록되어 있다
- **WHEN** 같은 창고·유형 조합으로 정책 등록을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 정책의 임계값을 갱신한다
- **GIVEN** 정책이 `version=1`이고 `queue_depth_threshold=5`다
- **WHEN** `expected_version=1`로 `queue_depth_threshold=8`로 갱신을
  요청한다
- **THEN** 정책의 `queue_depth_threshold`가 `8`로 바뀌고 `version`이
  증가한다

#### Scenario: 버전이 어긋나면 갱신이 거부된다
- **GIVEN** 정책의 현재 `version=3`이다
- **WHEN** `expected_version=2`로 갱신을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 정책이 바뀌지 않는다

#### Scenario: 창고 스코프가 없는 사용자는 정책을 등록할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고에 정책 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 설비 수동 라우팅 제외
시스템은 `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` 역할의 사용자가 특정 설비를 병목 판정 여부와 무관하게 자동 라우팅 대상에서 강제로 제외할 수 있어야 한다(SHALL). 제외 등록은 사유(`reason`)를 필수로 받아야 한다(MUST). 이미 활성 제외가 있는 설비에는 중복으로 제외를 등록할 수 없어야 한다(SHALL NOT). 시스템은 활성 제외를 해제할 수 있어야 하며(SHALL), 해제는 `expected_version`을 검증해야 한다(MUST).

#### Scenario: 계획 정비를 이유로 설비를 강제 제외한다
- **GIVEN** 설비 `SRM-02`에 활성 제외가 없다
- **WHEN** `reason='계획 정비'`로 라우팅 제외를 요청한다
- **THEN** `status='ACTIVE'`인 제외 레코드가 생성되고 `document_id`가
  반환된다

#### Scenario: 이미 제외된 설비를 중복으로 제외할 수 없다
- **GIVEN** 설비 `SRM-02`에 이미 `ACTIVE` 제외 레코드가 있다
- **WHEN** 같은 설비에 라우팅 제외를 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 제외를 해제해 자동 라우팅 대상으로 복귀시킨다
- **GIVEN** 설비 `SRM-02`에 `ACTIVE` 제외 레코드가 있다
- **WHEN** 올바른 `expected_version`으로 제외 해제를 요청한다
- **THEN** 제외 레코드 상태가 `CLEARED`로 바뀌고 `cleared_by`,
  `cleared_at`이 기록된다

#### Scenario: 이미 해제된 제외를 다시 해제할 수 없다
- **GIVEN** 제외 레코드가 이미 `CLEARED` 상태다
- **WHEN** 같은 레코드의 해제를 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 가용 설비 선택에 대한 병목 회피 반영
시스템은 `wms_wes-material-flow-control`의 "가용 설비 선택과 흐름 균형" Requirement가 정의하는 후보 선택 과정에서, 이 계약의 강제 제외와 병목 판정을 반영해야 한다(SHALL). 활성 제외가 있는 설비는 다른 후보가 전혀 없는 경우에도 후보에서 완전히 제외되어야 한다(SHALL NOT 선택). 병목으로 판정된 설비는, 병목이 아닌 후보가 하나 이상 있으면 후순위로 밀려야 하며(SHOULD), 병목이 아닌 후보가 전혀 없으면 병목 설비라도 선택되어야 한다(SHALL) — 작업이 무기한 대기하는 것을 막기 위한 폴백이다. 병목이 아닌 후보 또는 병목 후보 그룹 안에서는 `wms_wes-material-flow-control`이 정의한 기존 tie-break(최근 완료 건수 최소)가 그대로 적용되어야 한다(SHALL).

#### Scenario: 강제 제외된 설비만 후보일 때는 선택되지 않는다
- **GIVEN** 조건에 맞는 `IDLE` 설비가 `AGV-07` 하나뿐이고, 그 설비는
  현재 활성 라우팅 제외 상태다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** `AGV-07`이 선택되지 않고 업무 오더가 `QUEUED` 상태를 유지하며
  결과에 가용 설비 부족 경고가 포함된다

#### Scenario: 병목 후보와 비병목 후보가 함께 있으면 비병목 후보가 선택된다
- **GIVEN** 조건에 맞는 `IDLE` 설비가 `AGV-07`(병목 플래그)과
  `AGV-08`(비병목) 둘이다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** `AGV-08`에 설비 명령이 디스패치된다

#### Scenario: 모든 후보가 병목이어도 그중에서 선택된다
- **GIVEN** 조건에 맞는 `IDLE` 설비가 `AGV-07`, `AGV-08` 둘뿐이고 둘 다
  병목으로 판정되어 있다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** 두 설비 중 `wms_wes-material-flow-control`의 기존 tie-break
  규칙(최근 완료 건수 최소)에 따라 하나가 선택되고, 업무 오더가 `QUEUED`로
  남지 않는다

#### Scenario: 강제 제외와 병목 플래그는 다르게 취급된다
- **GIVEN** 조건에 맞는 `IDLE` 설비가 `AGV-07`(병목 플래그) 하나뿐이고,
  강제 제외는 걸려 있지 않다
- **WHEN** 업무 오더 디스패치를 시도한다
- **THEN** `AGV-07`에 설비 명령이 디스패치된다 — 병목 플래그만으로는
  유일한 후보를 배제하지 않는다(위 "강제 제외된 설비만 후보일 때" 시나리오와
  대비)

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 모든 테이블·뷰(라우팅 정책, 라우팅 제외, 부하 신호, 병목 판정)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·명령이 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT) — 기존 `wms_wcs-equipment-control`, `wms_wes-material-flow-control`과 동일한 RLS 패턴을 따른다.

#### Scenario: 다른 테넌트의 설비 라우팅 정보에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 설비의 강제 제외를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 허용되지 않은 역할은 라우팅 정책을 등록할 수 없다
- **GIVEN** 요청자가 `WMS_ADMIN`도 `WAREHOUSE_MANAGER`도 아니다
- **WHEN** 라우팅 정책 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 라우팅 정책 등록·갱신, 설비 강제 제외·해제를 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름), `entity_type`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 라우팅 정책 등록이 감사 이벤트를 남긴다
- **WHEN** 라우팅 정책이 성공적으로 등록된다
- **THEN** `wms.audit_events`에 `command='wms_register_wcs_routing_policy'`,
  `entity_type='wcs_routing_policy'`인 레코드가 생성된다

#### Scenario: 설비 강제 제외가 감사 이벤트를 남긴다
- **WHEN** 설비가 성공적으로 라우팅에서 강제 제외된다
- **THEN** `wms.audit_events`에 `command='wms_exclude_equipment_from_routing'`,
  `entity_type='wcs_routing_override'`인 레코드가 생성되고 `after`에
  `status='ACTIVE'`가 담긴다
