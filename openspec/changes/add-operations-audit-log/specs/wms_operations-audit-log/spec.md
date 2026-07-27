# 자연어 감사 로그(Operations Audit Log) 계약

## Purpose

WMS가 이미 모든 쓰기 명령을 구조화된 형태(`command`, `entity_type`,
`entity_id`, 변경 전/후 JSONB)로 기록하는 `wms.audit_events` 위에, 감사·
재무 담당자가 그 기록을 결정론적인 한국어 문장으로 요약해 읽고, 기간·
행위자·엔티티·명령으로 걸러 조회·내보내기 할 수 있는 목적 지향 계약을
정의한다. 이 계약은 새로운 로깅 메커니즘을 만들지 않으며, 데이터베이스
내부에서 LLM을 호출하는 요약 생성도 다루지 않는다.

## ADDED Requirements

### Requirement: 감사 이벤트의 결정론적 한국어 요약
시스템은 각 감사 이벤트를 `command`, `entity_type`, 변경 전/후(`before`/`after`) 값에 기반한 결정론적 규칙으로 사람이 읽을 수 있는 한국어 문장으로 요약할 수 있어야 한다(SHALL). 요약 생성은 외부 LLM 호출 없이 데이터베이스 안에서 계산되어야 한다(SHALL NOT 외부 LLM 호출). 아직 전용 요약 규칙이 없는 새로운 명령에 대해서도 요약 생성이 실패하거나 빈 값을 반환하지 않고, `entity_type`과 `command`를 사용한 범용 문장을 반환해야 한다(SHALL).

#### Scenario: 알려진 명령에 대해 전용 한국어 요약 문장을 생성한다
- **GIVEN** `command='wms_confirm_purchase_order'`, `entity_type='purchase_order'`인
  감사 이벤트가 존재한다
- **WHEN** 이 이벤트의 요약을 요청한다
- **THEN** 해당 명령에 특화된 한국어 문장(발주 확정을 설명하는 문장)이
  반환된다

#### Scenario: 전용 규칙이 없는 새 명령도 범용 요약으로 대체된다
- **GIVEN** 요약 규칙에 아직 등록되지 않은 `command='wms_new_future_command'`,
  `entity_type='future_entity'`인 감사 이벤트가 존재한다
- **WHEN** 이 이벤트의 요약을 요청한다
- **THEN** 오류 없이 `entity_type`과 `command`를 포함한 범용 한국어 문장이
  반환된다

#### Scenario: before/after 일부 필드가 비어 있어도 요약이 깨지지 않는다
- **GIVEN** `before`가 `NULL`이고 `after`만 채워진 감사 이벤트가 존재한다
  (신규 생성 명령의 전형적인 형태)
- **WHEN** 이 이벤트의 요약을 요청한다
- **THEN** 오류 없이 `after` 값만을 반영한 한국어 요약 문장이 반환된다

### Requirement: 에이전트 판단 근거의 요약 반영
시스템은 감사 이벤트와 동일한 상관관계 ID(`correlation_id`)를 가진 에이전트 판단 근거 기록이 존재하면 그 내용을 한국어 요약 문장에 포함해야 한다(SHALL). 그런 판단 근거 기록이 없으면 요약은 `command`/`entity_type`/`before`/`after`만으로 구성되어야 한다(SHALL). 이 요구사항은 판단 근거 기록 자체를 이 계약이 생성하거나 소유한다고 규정하지 않는다 — 다른 계약이 같은 `correlation_id`로 남긴 판단 근거를 조회 시점에 함께 보여줄 뿐이다.

#### Scenario: 판단 근거가 있는 에이전트 실행 이벤트를 요약한다
- **GIVEN** `command='wms_dispatch_equipment_command'`인 감사 이벤트가
  존재하고, 같은 `correlation_id`로 '재고 부족으로 대체 설비로 재배치'라는
  판단 근거 기록이 함께 존재한다
- **WHEN** 이 이벤트의 요약을 요청한다
- **THEN** 반환된 한국어 문장에 판단 근거 내용이 포함된다

#### Scenario: 사람이 수행한 명령은 판단 근거 없이 요약된다
- **GIVEN** 같은 `correlation_id`를 가진 판단 근거 기록이 존재하지 않는
  감사 이벤트가 있다(사람이 직접 호출한 명령의 전형적인 형태)
- **WHEN** 이 이벤트의 요약을 요청한다
- **THEN** 오류 없이 판단 근거 문구 없는 한국어 요약 문장이 반환된다

### Requirement: 감사 로그 조회
시스템은 `WMS_ADMIN` 또는 `AUDITOR` 역할을 가진 사용자가 자신의 테넌트 범위 안에서 기간(`date_from`~`date_to`), 행위자(`actor_id`), 엔티티 종류(`entity_type`), 특정 엔티티(`entity_id`), 명령(`command`), 상관관계 ID(`correlation_id`)로 감사 이벤트를 필터링해 조회할 수 있어야 한다(SHALL). 조회 결과는 페이지네이션(`limit`, `offset`)을 지원해야 하며(MUST), 각 행에 한국어 요약과 전체 매칭 건수를 포함해야 한다(MUST).

#### Scenario: 감사자가 기간과 엔티티 종류로 감사 로그를 조회한다
- **GIVEN** `AUDITOR` 역할을 가진 사용자가 테넌트 A에 속해 있고, 테넌트 A에
  `entity_type='purchase_order'`인 감사 이벤트가 여러 건 존재한다
- **WHEN** `date_from='2026-07-01'`, `date_to='2026-07-31'`,
  `entity_type='purchase_order'`로 조회를 요청한다
- **THEN** 그 기간·엔티티 종류에 해당하는 이벤트만 한국어 요약과 함께
  최신순으로 반환된다

#### Scenario: 페이지네이션으로 다음 페이지를 조회한다
- **GIVEN** 필터 조건에 매칭되는 감사 이벤트가 120건 존재한다
- **WHEN** `limit=50`, `offset=50`으로 조회를 요청한다
- **THEN** 51번째부터 100번째까지의 이벤트가 반환되고, 응답에 전체 매칭
  건수(120)가 포함된다

#### Scenario: 권한이 없는 역할은 감사 로그를 조회할 수 없다
- **GIVEN** `INBOUND_OPERATOR` 역할만 가진 사용자가 있다
- **WHEN** 이 사용자가 감사 로그 조회를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 다른 테넌트의 감사 이벤트는 조회되지 않는다
- **GIVEN** 사용자가 테넌트 A의 `AUDITOR`다
- **WHEN** `tenant_id`를 테넌트 B로 지정해 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 로그 내보내기
시스템은 `WMS_ADMIN` 또는 `AUDITOR` 역할을 가진 사용자가 감사 로그 조회와 동일한 필터 조건으로 필터링된 이벤트 전체 집합을 CSV/보고서 생성에 쓸 수 있는 형태로 한 번에 내보낼 수 있어야 한다(SHALL). 내보내기 대상 건수가 안전 상한(10,000건)을 넘으면 요청을 거부하고 기간을 좁히도록 안내해야 한다(SHALL).

#### Scenario: 감사자가 한 달치 감사 로그를 내보낸다
- **GIVEN** `AUDITOR` 역할을 가진 사용자가 있고, 테넌트 A의 지난달 감사
  이벤트가 200건 존재한다
- **WHEN** 지난달 범위로 내보내기를 요청한다
- **THEN** 200건 전체가 한국어 요약을 포함한 형태로 반환된다

#### Scenario: 안전 상한을 초과하는 내보내기는 거부된다
- **GIVEN** 필터 조건에 매칭되는 이벤트가 10,000건을 초과한다
- **WHEN** 그 조건으로 내보내기를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 아무 것도 내보내지지 않는다

#### Scenario: 권한이 없는 사용자는 내보내기를 요청할 수 없다
- **GIVEN** `QUALITY_INSPECTOR` 역할만 가진 사용자가 있다
- **WHEN** 이 사용자가 감사 로그 내보내기를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 내보내기 행위 자체의 자기 감사
시스템은 감사 로그 내보내기가 성공적으로 수행될 때마다 그 호출 자체를 `wms.audit_events`에 새로운 감사 이벤트로 기록해야 한다(SHALL). 이 자기 감사 이벤트는 실행한 행위자, 사용된 필터 조건, 발생 시각을 포함해야 한다(MUST).

#### Scenario: 내보내기 호출이 스스로 감사 이벤트를 남긴다
- **GIVEN** `AUDITOR` 역할을 가진 사용자가 지난달 범위로 내보내기를
  요청해 성공한다
- **WHEN** 그 직후 감사 로그를 다시 조회한다
- **THEN** `command='wms_export_audit_log'`, `entity_type='audit_export'`인
  새 이벤트가 조회 결과에 포함되고, 그 이벤트의 `after`에는 이번에 사용된
  필터 조건이 담겨 있다

### Requirement: 조회/내보내기 표면의 역할 게이트와 기존 열람 정책의 분리
시스템은 `wms.audit_events` 원본 테이블에 대한 기존 테넌트 단위 열람 정책을 변경하지 않아야 한다(SHALL NOT). 감사 로그 조회/내보내기 RPC는 그 위에 `WMS_ADMIN`, `AUDITOR` 역할만 호출할 수 있는 별도의 역할 검사를 추가해야 한다(SHALL) — 원본 테이블 직접 열람과 요약/필터/내보내기 표면은 서로 다른 접근 통제 수준을 가진다.

#### Scenario: 원본 테이블 직접 열람 권한은 그대로 유지된다
- **GIVEN** `INBOUND_OPERATOR` 역할을 가진 사용자가 자신의 테넌트에 속한다
- **WHEN** 이 사용자가 `wms.audit_events` 테이블을 직접 SELECT한다(RPC를
  거치지 않음)
- **THEN** 기존과 동일하게 자신의 테넌트 범위 안에서 조회가 성공한다

#### Scenario: 같은 사용자가 조회/내보내기 RPC는 호출할 수 없다
- **GIVEN** 위와 같은 `INBOUND_OPERATOR` 사용자
- **WHEN** 이 사용자가 `wms_query_audit_log` 또는 `wms_export_audit_log`
  RPC를 호출한다
- **THEN** 두 호출 모두 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 에이전트 판단 근거와의 느슨한 결합
시스템은 감사 이벤트에 연결된 에이전트 판단 근거가 존재하지 않아도 그 감사 이벤트를 정상적으로 조회·요약할 수 있어야 한다(SHALL). 판단 근거를 기록·소유하는 별도 계약(예: 에이전트 판단/제안 이력)이 이 계약과 독립적으로 존재하거나 부재할 수 있으며, 이 계약은 그 계약의 스키마나 쓰기 동작을 전제하지 않아야 한다(SHALL NOT).

#### Scenario: 판단 근거 계약이 아직 없어도 감사 이벤트는 정상적으로 기록·조회된다
- **GIVEN** 사람이 직접 호출한 명령(예: `wms_confirm_purchase_order`)이
  실행된다
- **WHEN** 이 명령이 감사 이벤트를 남긴 뒤 감사 로그 조회를 요청한다
- **THEN** 판단 근거 없이 이벤트가 정상 기록·조회되고, 요약 시에도 오류
  없이 처리된다

#### Scenario: 판단 근거가 연결된 이벤트는 조회 결과에 그대로 노출된다
- **GIVEN** 특정 `correlation_id`를 가진 감사 이벤트와, 같은
  `correlation_id`를 가진 에이전트 판단 근거 기록이 함께 존재한다
- **WHEN** 감사 로그 조회를 요청한다
- **THEN** 조회 결과의 해당 행에 판단 근거 원문과 그것이 반영된 한국어
  요약이 함께 포함된다
