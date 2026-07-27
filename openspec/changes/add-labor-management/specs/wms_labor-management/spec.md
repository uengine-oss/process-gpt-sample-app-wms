# 인력 관리 계약

## Purpose

작업자가 업무 처리의 시작·완료·중단을 명시적으로 기록하는 인력 활동 로그를
신설하고, 그 로그를 근거로 작업자별·역할별 생산성 집계, 트레일링 평균
처리량과 예상 물량에 기반한 단순 비율 인력 수요 추정, 기간별 생산성
리더보드를 제공하는 소프트웨어 계약을 정의한다. 이 계약은 범용 작업(task)
배정·claim·SLA 생명주기를 다루지 않으며(그런 모델은 이 저장소에 아직 없다),
머신러닝 기반 수요 예측이나 포인트/배지 게이미피케이션 시스템을 구현하지
않는다. 개인 생산성 데이터는 본인과 `WAREHOUSE_MANAGER`/`WMS_ADMIN`만 조회할
수 있다.

## ADDED Requirements

### Requirement: 인력 활동 시작 기록
시스템은 `INBOUND_OPERATOR`, `QUALITY_INSPECTOR`, `PROCESS_AGENT`, `WMS_ADMIN` 역할을 가진 사용자가 창고 스코프 안에서 인력 활동을 시작할 수 있어야 한다(SHALL). 활동은 `activity_type`(`RECEIVING`, `QUALITY_INSPECTION`, `PUTAWAY`, `DISPOSITION`, `OTHER` 중 하나)을 필수로 가져야 한다(MUST). `activity_type='OTHER'`인 경우 `activity_label`을 필수로 가져야 한다(MUST). 시작 직후 활동 상태는 `IN_PROGRESS`여야 한다(SHALL).

#### Scenario: 작업자가 입고 검수 활동을 시작한다
- **GIVEN** `INBOUND_OPERATOR` 역할을 가진 사용자가 대상 창고에 스코프를 가지고 있다
- **WHEN** `activity_type='RECEIVING'`, `linked_entity_type='receipt'`,
  `linked_entity_id='<receipt_id>'`로 활동 시작을 요청한다
- **THEN** 상태 `IN_PROGRESS`, `version=1`인 활동 레코드가 생성되고
  `document_id`, `status`, `version`을 포함한 결과가 반환된다

#### Scenario: OTHER 유형은 activity_label 없이 시작할 수 없다
- **WHEN** `activity_type='OTHER'`, `activity_label`을 생략하고 활동 시작을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 활동이 생성되지 않는다

#### Scenario: 창고 스코프가 없는 사용자는 활동을 시작할 수 없다
- **GIVEN** 사용자가 대상 창고에 대한 `warehouse_scopes`를 갖지 않는다
- **WHEN** 해당 창고에서 활동 시작을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 본인 명의 기록 원칙과 관리자 대리 기록
시스템은 활동 시작·완료·취소 요청의 `actor_id`가 요청자 본인과 일치하지 않으면 거부해야 한다(SHALL NOT 대리 기록 허용). 단 `WMS_ADMIN` 역할을 가진 사용자는 임의의 `actor_id`로 활동을 시작·완료·취소할 수 있어야 한다(SHALL).

#### Scenario: 다른 사람 명의로 활동을 시작할 수 없다
- **GIVEN** 사용자 A가 `INBOUND_OPERATOR`로 인증되어 있다
- **WHEN** 사용자 A가 `actor_id`를 사용자 B로 지정해 활동 시작을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환되고 활동이 생성되지 않는다

#### Scenario: WMS_ADMIN은 다른 사용자 명의로 활동을 대신 기록할 수 있다
- **GIVEN** `WMS_ADMIN` 역할을 가진 사용자가 대상 창고에 스코프를 가지고 있다
- **WHEN** 오프라인으로 업무를 처리한 작업자 B의 명의(`actor_id`)로 활동 시작·완료를 대신 요청한다
- **THEN** 활동이 정상적으로 생성·완료되고 `actor_id`는 작업자 B로 기록된다

### Requirement: 인력 활동 완료 기록
시스템은 `IN_PROGRESS` 상태의 활동을 시작한 본인(또는 `WMS_ADMIN`)이 완료로 전환할 수 있어야 한다(SHALL). 완료 시 처리 수량(`unit_count`, 선택)을 함께 기록할 수 있어야 한다(MAY). 완료 시각과 시작 시각의 차이로 계산되는 처리 시간(`duration_seconds`)이 저장되어야 한다(SHALL). `IN_PROGRESS`가 아닌 활동은 완료할 수 없어야 한다(SHALL NOT).

#### Scenario: 처리 수량과 함께 활동을 완료한다
- **GIVEN** `IN_PROGRESS` 상태의 활동이 있다(시작 시각 `09:00:00`)
- **WHEN** `09:12:30`에 `unit_count=48`로 완료를 요청한다
- **THEN** 활동 상태가 `COMPLETED`로 바뀌고 `duration_seconds=750`,
  `unit_count=48`이 저장된다

#### Scenario: 이미 완료된 활동은 다시 완료할 수 없다
- **GIVEN** `COMPLETED` 상태의 활동이 있다
- **WHEN** 같은 활동에 완료를 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 상태는 바뀌지 않는다

#### Scenario: 버전 충돌 시 완료가 거부된다
- **GIVEN** 활동의 현재 `version`이 2다
- **WHEN** `expected_version=1`로 완료를 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 상태는 바뀌지 않는다

### Requirement: 인력 활동 취소
시스템은 `IN_PROGRESS` 상태의 활동을 시작한 본인(또는 `WMS_ADMIN`)이 취소할 수 있어야 한다(SHALL). 취소된 활동은 생산성 집계의 완료 건수·처리 시간 통계에 포함되지 않아야 한다(SHALL NOT).

#### Scenario: 잘못 시작한 활동을 취소한다
- **GIVEN** `IN_PROGRESS` 상태의 활동이 있다
- **WHEN** 시작한 본인이 `reason='다른 작업으로 재배정됨'`으로 취소를 요청한다
- **THEN** 활동 상태가 `CANCELLED`로 바뀌고, 이후 해당 창고·기간의 생산성 집계
  조회 결과에서 이 활동은 완료 건수·처리 시간 계산에서 제외된다

### Requirement: 작업자별 생산성 집계 조회
시스템은 인증된 창고 스코프 사용자가 기간(`period_start`, `period_end`)을 지정해 완료된 활동을 작업자별·역할별·일자별·활동유형별로 집계 조회할 수 있어야 한다(SHALL). 집계 결과는 완료 건수, 평균 처리 시간, 합계 처리 시간, 합계 처리 수량을 포함해야 한다(MUST).

#### Scenario: 관리자가 창고 전체 생산성을 조회한다
- **GIVEN** `WAREHOUSE_MANAGER`가 대상 창고에 스코프를 가지고 있고, 해당 기간
  동안 여러 작업자가 완료한 활동이 존재한다
- **WHEN** 기간을 지정해 생산성 조회를 요청한다
- **THEN** 창고 스코프 내 모든 작업자의 작업자별·역할별·일자별 집계가
  반환된다

#### Scenario: 일반 작업자는 본인 집계만 조회된다
- **GIVEN** `INBOUND_OPERATOR` 역할의 사용자 A와 동료 사용자 B가 같은 창고에서
  각각 활동을 완료했다
- **WHEN** 사용자 A가 기간을 지정해 생산성 조회를 요청한다
- **THEN** 사용자 A 본인의 집계만 반환되고 사용자 B의 집계는 포함되지 않는다

### Requirement: 인력 수요 추정 (단순 비율 계산)
시스템은 `WAREHOUSE_MANAGER` 또는 `WMS_ADMIN` 역할을 가진 사용자가 역할(`role`)과 예상 물량(`expected_volume`)을 입력해 필요 인력 수를 추정 조회할 수 있어야 한다(SHALL). 추정은 트레일링 N일(기본 7일)의 해당 역할 평균 시간당 처리량과 표준 근무시간(기본 8시간)을 근거로 한 단순 비율 계산이어야 하며(MUST), 머신러닝 기반 예측이 아님을 응답에 명시해야 한다(MUST). 트레일링 기간에 해당 역할의 완료된 활동 표본이 없으면 추정치를 계산하지 않아야 한다(SHALL NOT).

#### Scenario: 예상 물량 기준으로 필요 인력을 추정한다
- **GIVEN** 최근 7일간 `INBOUND_OPERATOR` 역할의 평균 시간당 처리량이 20건이다
- **WHEN** `role='INBOUND_OPERATOR'`, `expected_volume=480`으로 인력 수요
  추정을 요청한다
- **THEN** 시간당 20건 × 8시간(표준 근무시간) = 1인당 일일 160건 처리 가능을
  근거로 `recommended_headcount=3`(480÷160, 올림)이 반환되고, 계산 근거로
  쓰인 트레일링 일수와 표본 건수가 함께 반환된다

#### Scenario: 표본이 없는 역할은 추정할 수 없다
- **GIVEN** 트레일링 기간 동안 `QUALITY_INSPECTOR` 역할의 완료된 활동이 하나도
  없다
- **WHEN** `role='QUALITY_INSPECTOR'`로 인력 수요 추정을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 추정치는 계산되지 않는다

#### Scenario: 일반 작업자는 인력 수요 추정을 조회할 수 없다
- **GIVEN** 요청자가 `INBOUND_OPERATOR`이며 `WAREHOUSE_MANAGER`도 `WMS_ADMIN`도
  아니다
- **WHEN** 인력 수요 추정을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 생산성 리더보드 조회 (게이미피케이션 경량 대응)
시스템은 인증된 창고 스코프 사용자가 기간과 지표(`completed_count`, `total_unit_count`, `avg_duration_seconds` 중 하나)를 지정해 작업자 순위를 조회할 수 있어야 한다(SHALL). 포인트·배지·레벨 같은 게임 메커니즘은 계산하지 않는다(SHALL NOT).

#### Scenario: 관리자가 처리 건수 기준 리더보드를 조회한다
- **GIVEN** `WAREHOUSE_MANAGER`가 대상 창고에 스코프를 가지고 있다
- **WHEN** 기간과 `metric='completed_count'`로 리더보드 조회를 요청한다
- **THEN** 창고 스코프 내 작업자들이 완료 건수 내림차순으로 정렬되어 반환된다

#### Scenario: 일반 작업자가 리더보드를 조회하면 본인 행만 반환된다
- **GIVEN** `INBOUND_OPERATOR` 역할의 사용자가 리더보드를 조회한다
- **WHEN** 기간과 `metric='completed_count'`로 리더보드 조회를 요청한다
- **THEN** 오류 없이 요청이 성공하되, 결과에는 본인 행만 포함되고 다른
  작업자의 순위나 수치는 노출되지 않는다

### Requirement: 개인 생산성 데이터 접근 통제
시스템은 개인별 생산성 데이터(활동 로그, 집계, 리더보드)에 대해 본인이거나 `WAREHOUSE_MANAGER`/`WMS_ADMIN` 역할을 가진 사용자만 조회할 수 있도록 제한해야 한다(SHALL). 이 제한은 테이블 조회와 집계 RPC 호출 양쪽에서 동일하게 적용되어야 한다(MUST).

#### Scenario: 다른 테넌트의 인력 활동에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에만 소속되어 있다
- **WHEN** 테넌트 B의 인력 활동 로그를 직접 조회한다
- **THEN** 결과가 반환되지 않는다(RLS에 의해 필터링됨)

#### Scenario: 동료의 개별 활동 로그를 직접 조회할 수 없다
- **GIVEN** `INBOUND_OPERATOR` 역할의 사용자 A와 동료 사용자 B가 같은 창고에
  소속되어 있다
- **WHEN** 사용자 A가 `wms.labor_activities` 테이블을 직접 조회한다
- **THEN** 사용자 A 본인이 기록한 행만 반환되고, 사용자 B가 기록한 행은
  반환되지 않는다

### Requirement: 인력 활동 감사 추적
시스템은 인력 활동의 시작·완료·취소 각각을 감사 이벤트로 기록해야 한다(SHALL). 감사 이벤트는 명령 이름, 대상 활동, 변경 전후 상태를 포함해야 한다(MUST).

#### Scenario: 활동 완료가 감사 이벤트로 남는다
- **GIVEN** `IN_PROGRESS` 상태의 활동이 있다
- **WHEN** 완료 요청이 성공한다
- **THEN** `wms.audit_events`에 `command='wms_complete_labor_activity'`,
  해당 활동을 가리키는 `entity_id`, 완료 후 상태를 담은 `after`가 기록된다
