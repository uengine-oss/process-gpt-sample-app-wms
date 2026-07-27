# 슬롯팅 최적화 계약

## Purpose

SKU 출하 빈도에 따라 고빈도 SKU를 접근성이 좋은 보관 위치로, 저빈도 SKU를
접근성이 낮은 위치로 재배치하도록 돕는 계약을 정의한다. 이 계약은 창고
안에 보관 위치를 등록하고, SKU가 현재 어느 위치에 배정되어 있는지를
운영자가 선언하며, `AVAILABLE` 상태 재고의 소비(출고) 이력으로부터 SKU별
출하 속도 등급(A/B/C)을 계산하고, 그 등급과 현재 배정된 위치의 접근성
사이의 괴리를 찾아 재배치 추천을 생성한다. 추천은 사람 운영자
(`WMS_ADMIN` 또는 `WAREHOUSE_MANAGER`)가 검토·승인해야만 실제 배정에
반영된다 — 이 계약은 재배치를 자동으로 실행하지 않는다. 실제 이동 경로
계산, 위치 용량 관리 규칙, 위치-품목 적합성 규칙, 물리적 이동 작업 배정은
이 계약의 범위 밖이다.

## ADDED Requirements

### Requirement: 창고별 보관 위치 등록
시스템은 `WMS_ADMIN` 또는 `WAREHOUSE_MANAGER` 역할을 가진 사용자가 창고 스코프 안에서 보관 위치를 레지스트리에 등록할 수 있어야 한다(SHALL). 위치는 최소한 `zone_code`, 창고 내 고유한 `location_code`, 낮을수록 접근성이 좋음을 의미하는 정수 `accessibility_rank`를 가져야 한다(MUST). 등록 직후 위치 상태는 `ACTIVE`여야 한다(SHALL). 같은 창고에 동일한 `location_code`가 이미 있으면 등록이 거부되어야 한다(SHALL NOT).

#### Scenario: 창고 담당자가 보관 위치를 등록한다
- **GIVEN** 사용자가 창고 A에 대해 `WAREHOUSE_MANAGER` 권한을 가진다
- **WHEN** `zone_code='PACK_ADJACENT'`, `location_code='A-01-01'`,
  `accessibility_rank=1`로 위치 등록을 요청한다
- **THEN** `status='ACTIVE'`, `version=1`인 위치 레코드가 생성되고
  `document_id`, `status`, `version`을 포함한 결과가 반환된다

#### Scenario: 같은 창고에 동일한 위치 코드를 중복 등록할 수 없다
- **GIVEN** 창고 A에 `location_code='A-01-01'`인 위치가 이미 등록되어 있다
- **WHEN** 같은 창고에 동일한 `location_code`로 위치 등록을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 신규 위치가 생성되지 않는다

#### Scenario: 권한이 없는 사용자는 위치를 등록할 수 없다
- **GIVEN** 사용자가 `WMS_ADMIN`도 `WAREHOUSE_MANAGER`도 아니다
- **WHEN** 위치 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 보관 위치 활성 상태 관리
시스템은 `WMS_ADMIN` 또는 `WAREHOUSE_MANAGER` 역할을 가진 사용자가 위치를 `ACTIVE`와 `INACTIVE` 사이에서 전환할 수 있어야 한다(SHALL). 전환은 위치의 `expected_version`을 검증해야 한다(MUST). `INACTIVE` 위치는 신규 SKU-위치 배정이나 재배치 추천의 대상 위치로 선택되지 않아야 한다(SHALL NOT).

#### Scenario: 위치를 비활성화한다
- **GIVEN** `ACTIVE` 상태이고 `version=1`인 위치가 있다
- **WHEN** `expected_version=1`로 `INACTIVE` 전환을 요청한다
- **THEN** 위치 상태가 `INACTIVE`로 바뀌고 `version=2`가 된다

#### Scenario: 버전이 어긋나면 상태 전환이 거부된다
- **GIVEN** 위치의 실제 `version`이 `2`다
- **WHEN** `expected_version=1`로 상태 전환을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 위치 상태가 바뀌지 않는다

### Requirement: SKU-위치 배정 선언 및 재배정
시스템은 `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `INBOUND_OPERATOR` 역할을 가진 사용자가 SKU가 현재 어느 위치에 있다고 선언할 수 있어야 한다(SHALL). 하나의 창고 안에서 SKU 하나는 동시에 활성 배정을 하나만 가져야 한다(SHALL). 이미 활성 배정이 있는 SKU에 신규 배정 선언을 요청하면 거부되어야 하며, 대신 재배정 경로로 위치를 바꿀 수 있어야 한다(SHALL). 재배정은 `expected_version`을 검증해야 한다(MUST).

#### Scenario: SKU의 현재 위치를 최초로 선언한다
- **GIVEN** 제품 `SKU-100`이 창고 A에 아직 활성 배정이 없다
- **WHEN** `location_id`를 `A-01-01`로 지정해 배정 선언을 요청한다
- **THEN** `assigned_reason='MANUAL_DECLARATION'`인 배정 레코드가
  생성되고 `version=1`이 반환된다

#### Scenario: 이미 배정이 있는 SKU에는 신규 배정을 선언할 수 없다
- **GIVEN** `SKU-100`이 이미 창고 A에서 `A-01-01`에 활성 배정되어 있다
- **WHEN** 같은 SKU에 신규 배정 선언을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: SKU를 다른 위치로 재배정한다
- **GIVEN** `SKU-100`이 `A-01-01`에 `version=1`로 배정되어 있다
- **WHEN** `expected_version=1`로 `location_id`를 `B-05-02`로 바꾸는
  재배정을 요청한다
- **THEN** 배정의 `location_id`가 `B-05-02`로 바뀌고 `version=2`가 된다

### Requirement: 속도 등급별 목표 접근성 정책 관리
시스템은 `WMS_ADMIN` 또는 `WAREHOUSE_MANAGER` 역할을 가진 사용자가 창고 단위로 속도 등급(`A`/`B`/`C`)마다 목표 접근성 순위 상한 (`max_accessibility_rank`)을 등록·갱신할 수 있어야 한다(SHALL). 동일한 창고·등급 조합에는 정책이 하나만 존재할 수 있어야 한다(SHALL). 갱신은 정책의 `expected_version`을 검증해야 한다(MUST). 정책이 없는 등급은 재배치 추천 생성에서 제외되고, 그 사실이 응답에 명시되어야 한다(SHALL, 아래 "재배치 추천 생성" Requirement 참고).

#### Scenario: 등급별 목표 접근성 정책을 등록한다
- **GIVEN** 창고 A에 `A`등급 정책이 아직 없다
- **WHEN** `velocity_class='A'`, `max_accessibility_rank=5`로 정책 등록을
  요청한다
- **THEN** `version=1`인 정책 레코드가 생성된다

#### Scenario: 같은 창고·등급에 정책을 중복 등록할 수 없다
- **GIVEN** 창고 A에 `A`등급 정책이 이미 등록되어 있다
- **WHEN** 같은 창고·등급 조합으로 정책 등록을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: SKU 출하 속도 계산
시스템은 `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `PROCESS_AGENT` 역할을 가진 사용자가 지정한 관찰 윈도우(`window_start`, `window_end`) 안에서, 재고 원장의 `AVAILABLE` 상태이면서 `qty_delta`가 음수인 항목만을 SKU별 소비 신호로 집계해 출하 속도 스냅샷을 계산할 수 있어야 한다(SHALL). 집계는 SKU별 소비 수량 합계(`outbound_qty`)와 소비 이벤트 건수 (`outbound_event_count`)를 산출해야 한다(MUST). 누적 소비 수량 비중이 상위 80%에 도달할 때까지의 SKU는 `A`등급, 80~95%는 `B`등급, 나머지는 `C`등급으로 분류되어야 한다(SHALL). 지정된 윈도우 안에 그런 소비 신호가 하나도 없는 SKU는 등급을 매기지 않고 계산 대상에서 제외되어야 하며(SHALL NOT), 계산 결과 응답에는 제외된 SKU 수(`skipped_no_data_count`)가 명시되어야 한다(MUST) — 신호가 없다고 임의의 기본 등급을 매기지 않는다.

#### Scenario: 소비 이력이 있는 SKU들이 등급으로 분류된다
- **GIVEN** 창고 A에서 지정 윈도우 안에 `SKU-100`, `SKU-200`, `SKU-300`에
  `AVAILABLE` 상태 음수 `qty_delta` 이력이 있고, 누적 비중이 각각 80%,
  95%, 100% 지점에 걸린다
- **WHEN** 그 윈도우로 속도 계산을 요청한다
- **THEN** `SKU-100`은 `A`, `SKU-200`은 `B`, `SKU-300`은 `C` 등급의
  스냅샷이 생성되고, 세 스냅샷이 동일한 `batch_id`를 공유한다

#### Scenario: 소비 이력이 전혀 없는 SKU는 등급 없이 명시적으로 제외된다
- **GIVEN** 창고 A에 등록된 제품 중 지정 윈도우 안에 `AVAILABLE` 상태
  음수 `qty_delta` 이력이 있는 제품이 하나도 없다(이 저장소가 현재
  소비/출고 차감 경로를 구현하지 않은 상태와 같은 조건)
- **WHEN** 그 윈도우로 속도 계산을 요청한다
- **THEN** 생성되는 스냅샷이 0건이고, 응답의 `included_product_count`는
  `0`, `skipped_no_data_count`는 창고에 등록된 대상 제품 수와 같다

#### Scenario: 일부 SKU만 소비 이력이 있으면 나머지는 개별적으로 제외된다
- **GIVEN** 창고 A에 제품 5종이 등록되어 있고, 그중 2종에만 지정 윈도우
  안에 소비 신호가 있다
- **WHEN** 그 윈도우로 속도 계산을 요청한다
- **THEN** 스냅샷이 2건 생성되고, 응답의 `skipped_no_data_count`는 `3`이다

### Requirement: 재배치 추천 생성
시스템은 `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `PROCESS_AGENT` 역할을 가진 사용자가 특정 속도 계산 배치(`batch_id`)의 스냅샷들을 창고의 등급별 정책과 비교해 재배치 추천을 생성할 수 있어야 한다(SHALL). SKU의 현재 배정된 위치가 있고 그 위치의 `accessibility_rank`가 SKU 등급의 `max_accessibility_rank`를 초과하면, 그 등급 상한을 만족하는 다른 위치로의 재배치 추천이 생성되어야 한다(SHALL). SKU에 현재 배정이 없으면 `current_location_id`가 `null`이고 사유가 `UNASSIGNED_HIGH_VELOCITY`인 추천이 생성되어야 한다(SHALL). 창고에 등급 정책이 없는 속도 등급의 SKU는 추천 생성에서 제외되어야 하며(SHALL NOT), 제외된 등급 목록이 응답에 포함되어야 한다(MUST). 이미 등급 상한을 만족하는 위치에 배정된 SKU는 추천을 생성하지 않아야 한다(SHALL NOT).

#### Scenario: 접근성 상한을 벗어난 고빈도 SKU에 재배치가 추천된다
- **GIVEN** `SKU-100`이 `A`등급 스냅샷을 가지고, 창고 A의 `A`등급 정책은
  `max_accessibility_rank=5`이며, `SKU-100`은 현재 `accessibility_rank=20`인
  위치에 배정되어 있다
- **WHEN** 그 스냅샷 배치로 추천 생성을 요청한다
- **THEN** `SKU-100`에 대해 `status='PENDING'`,
  `reason_code='RELOCATE_UNDERSERVED'`이고 `recommended_location_id`의
  `accessibility_rank`가 `5` 이하인 추천이 생성된다

#### Scenario: 이미 적절한 위치에 있는 SKU는 추천되지 않는다
- **GIVEN** `SKU-200`이 `A`등급이고, 이미 `accessibility_rank=3`인
  위치(등급 상한 `5` 이하)에 배정되어 있다
- **WHEN** 추천 생성을 요청한다
- **THEN** `SKU-200`에 대한 추천이 생성되지 않는다

#### Scenario: 위치가 없는 고빈도 SKU에도 배정 추천이 생성된다
- **GIVEN** `SKU-300`이 `A`등급 스냅샷을 가지지만 창고 A에 활성 배정이
  없다
- **WHEN** 추천 생성을 요청한다
- **THEN** `current_location_id=null`, `reason_code='UNASSIGNED_HIGH_VELOCITY'`인
  추천이 생성된다

#### Scenario: 정책이 없는 등급은 추천 생성에서 제외된다
- **GIVEN** 창고 A에 `B`등급 정책이 아직 등록되어 있지 않고, `B`등급
  스냅샷을 가진 SKU가 있다
- **WHEN** 그 배치로 추천 생성을 요청한다
- **THEN** 그 SKU에 대한 추천이 생성되지 않고, 응답의
  `skipped_no_policy_classes`에 `'B'`가 포함된다

### Requirement: 재배치 추천 검토(승인/반려)
시스템은 `WMS_ADMIN` 또는 `WAREHOUSE_MANAGER` 역할을 가진 사용자만 재배치 추천을 승인하거나 반려할 수 있어야 한다(SHALL). `PENDING` 상태가 아닌 추천에 대한 검토 요청은 거부되어야 한다(SHALL NOT). 검토는 추천의 `expected_version`을 검증해야 한다(MUST). 승인 또는 반려 시 검토자와 시각이 기록되어야 한다(MUST).

#### Scenario: 창고 관리자가 추천을 승인한다
- **GIVEN** `status='PENDING'`, `version=1`인 추천이 있다
- **WHEN** `WAREHOUSE_MANAGER`가 `expected_version=1`로 승인을 요청한다
- **THEN** 추천 상태가 `APPROVED`로 바뀌고 `reviewed_by`, `reviewed_at`가
  채워진다

#### Scenario: 추천을 반려한다
- **GIVEN** `status='PENDING'`인 추천이 있다
- **WHEN** 반려 사유와 함께 반려를 요청한다
- **THEN** 추천 상태가 `REJECTED`로 바뀌고 `review_reason`이 기록된다

#### Scenario: 이미 검토된 추천은 다시 검토할 수 없다
- **GIVEN** `status='APPROVED'`인 추천이 있다
- **WHEN** 같은 추천에 승인을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 권한이 없는 역할은 추천을 검토할 수 없다
- **GIVEN** 사용자가 `INBOUND_OPERATOR` 역할만 가진다
- **WHEN** 추천 승인을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 승인된 추천 적용
시스템은 `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `INBOUND_OPERATOR` 역할을 가진 사용자가 `APPROVED` 상태의 추천을 적용할 수 있어야 한다(SHALL). 적용은 SKU-위치 배정을 추천된 위치로 갱신(또는 신규 생성)하고 추천 상태를 `APPLIED`로 전이하는 것을 하나의 트랜잭션으로 처리해야 한다(MUST). `APPROVED`가 아닌 추천에 대한 적용 요청은 거부되어야 한다(SHALL NOT).

#### Scenario: 승인된 추천을 적용해 배정이 갱신된다
- **GIVEN** `status='APPROVED'`이고 기존 배정이 있는 SKU에 대한 추천이
  있다
- **WHEN** 그 추천의 적용을 요청한다
- **THEN** 해당 SKU의 배정 `location_id`가 추천된 위치로 바뀌고, 추천
  상태가 `APPLIED`로 바뀐다

#### Scenario: 미승인 추천은 적용할 수 없다
- **GIVEN** `status='PENDING'`인 추천이 있다
- **WHEN** 그 추천의 적용을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 배정이 바뀌지 않는다

#### Scenario: 배정이 없던 SKU의 추천을 적용하면 신규 배정이 생성된다
- **GIVEN** `status='APPROVED'`이고 `current_location_id=null`인 추천이
  있다
- **WHEN** 그 추천의 적용을 요청한다
- **THEN** 해당 SKU에 `assigned_reason='SLOTTING_RECOMMENDATION'`인 신규
  배정 레코드가 생성된다

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 모든 테이블에 대해 사용자가 접근 권한을 가진 창고의 데이터만 조회할 수 있도록 해야 한다(SHALL). 다른 테넌트나 접근 권한이 없는 창고의 위치, 배정, 정책, 속도 스냅샷, 추천 정보는 조회되지 않아야 한다(SHALL NOT).

#### Scenario: 접근 권한이 없는 창고의 추천은 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 접근 권한이 있고 창고 B에는 없다
- **WHEN** 재배치 추천 목록을 조회한다
- **THEN** 창고 A의 추천만 반환되고 창고 B의 추천은 포함되지 않는다

### Requirement: 감사 추적
시스템은 이 계약의 모든 쓰기 RPC(위치 등록/상태 전환, 배정 선언/재배정, 정책 등록/갱신, 추천 검토, 추천 적용) 성공 시 해당 명령과 변경 전후 상태를 감사 이벤트로 기록해야 한다(SHALL). 각 감사 이벤트는 실행한 사용자 (`actor_id`)와 시각을 포함해야 한다(MUST).

#### Scenario: 추천 승인이 감사 이벤트로 남는다
- **GIVEN** `WAREHOUSE_MANAGER`가 추천을 승인했다
- **WHEN** 그 추천의 감사 이력을 조회한다
- **THEN** `command='wms_review_slotting_recommendation'`이고 승인한
  사용자의 `actor_id`가 포함된 감사 이벤트가 존재한다
