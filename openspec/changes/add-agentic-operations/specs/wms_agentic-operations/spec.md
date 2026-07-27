# 에이전틱 운영 계약

## Purpose

`docs/04-wms-wcs-market-feature-catalog.md`(§2.4, §4 Manhattan Active WM)가
정리한 Wave Coordinator Agent(웨이브 지연 자율 교정), Labor Agent(인력
불균형 감지·재배치), Associate Agent(작업자 온디바이스 가이던스)를 이
저장소에서 재현하기 위한 계약을 정의한다. 이 저장소의 제품은 모든 에이전트
오케스트레이션·자율 판단·HITL 워크플로우를 ProcessGPT(별도 BPM+에이전트
플랫폼, `docs/03-processgpt-integration.md`)에 위임하므로, 이 계약은 그
자체로 에이전트를 실행하지 않는다. 대신 ProcessGPT 쪽에서 실행되는 외부
에이전트(`PROCESS_AGENT` service identity)가 (1) 운영 신호를 조회하고,
(2) 이미 다른 계약에서 허용된 범위 안의 액션은 직접 호출하며, (3) 그
범위를 벗어나는 조치는 사람이 승인/거부할 수 있는 제안으로만 만들고,
(4) 모든 판단의 자연어 근거를 사람이 감사할 수 있도록 기록할 수 있게
하는 신호·제안·판단 로그 계약을 이 저장소 안에 정의한다. 이 계약은 신규
자율 실행 RPC나 예측 모델을 만들지 않는다.

## ADDED Requirements

### Requirement: 인력 작업량 불균형 신호 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 관찰 기간 안에서 작업자별 생산성 집계(완료 건수)와 전체 평균 대비 편차를 조회할 수 있어야 한다(SHALL). 조회 결과는 각 작업자의 완료 건수, 전체 평균 대비 편차 비율, `is_imbalanced` 여부를 포함해야 한다(MUST). 이 신호는 `wms_labor-management`가 정의하는 인력 활동 로그·생산성 집계 위에서 계산되어야 하며(MUST), 그 계약이 아직 구현되지 않은 환경에서는 항상 빈 결과를 반환해야 한다(SHALL) — 오류가 아니다. `PROCESS_AGENT` 역할은 창고 전체 작업자 간 비교 결과를 조회할 수 있어야 한다(SHALL) — 인력 불균형 감지는 본질적으로 여러 작업자를 비교하는 질문이므로, 이 조회에 한해 개인정보 비공개 기본 규칙의 명시적 예외를 둔다.

#### Scenario: 창고 담당자가 작업량 편차를 조회한다
- **GIVEN** 관찰 기간 안에 작업자 A가 12건, 작업자 B가 2건을 완료했다
- **WHEN** 창고의 인력 작업량 불균형 신호 조회를 요청한다
- **THEN** 작업자 A와 B 각각의 완료 건수와 편차 비율이 반환되고, 편차가
  임계값을 넘는 작업자는 `is_imbalanced=true`로 표시된다

#### Scenario: PROCESS_AGENT가 창고 전체 비교 결과를 조회한다
- **GIVEN** 창고에 작업자 A, B의 생산성 집계가 있다
- **WHEN** `PROCESS_AGENT`가 인력 작업량 불균형 신호 조회를 요청한다
- **THEN** 호출자 본인 행만이 아니라 작업자 A, B 모두의 집계가 반환된다

#### Scenario: 선행 계약이 구현되지 않은 환경에서는 빈 결과가 반환된다
- **GIVEN** `wms_labor-management`가 아직 구현되지 않았다
- **WHEN** 인력 작업량 불균형 신호 조회를 요청한다
- **THEN** 오류 없이 빈 결과 집합이 반환된다

#### Scenario: 다른 창고의 작업량 신호는 조회되지 않는다
- **GIVEN** 사용자가 창고 A에는 스코프가 있고 창고 B에는 스코프가 없다
- **WHEN** 창고 B의 인력 작업량 불균형 신호 조회를 요청한다
- **THEN** 결과가 비어 있거나 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 디스패치 지연 신호 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 지연 임계 시간을 초과해 대기 중인 업무 오더/웨이브의 목록과, 그 지연이 가용 설비 부족 때문인지 설비 병목 때문인지 구분되는 원인 정보를 조회할 수 있어야 한다(SHALL). 이 신호는 `wms_wes-material-flow-control`의 업무 오더/웨이브 상태와 `wms_wcs-bottleneck-routing`의 병목 판정을 조합해 계산되어야 한다(MUST). 두 계약이 아직 구현되지 않은 환경에서는 이 신호가 항상 빈 결과를 반환해야 하며(SHALL), 이는 오류가 아니다.

#### Scenario: 지연된 업무 오더가 병목 설비 때문임을 확인한다
- **GIVEN** 업무 오더가 지연 임계 시간을 넘겨 `QUEUED` 상태로 남아 있고,
  대상 설비 유형·구역의 유일한 후보 설비가 병목으로 판정되어 있다
- **WHEN** 디스패치 지연 신호 조회를 요청한다
- **THEN** 해당 업무 오더가 결과에 포함되고 지연 원인에 병목 관련 표시가
  포함된다

#### Scenario: 지연된 업무 오더가 가용 설비 부족 때문임을 확인한다
- **GIVEN** 업무 오더가 지연 임계 시간을 넘겨 `QUEUED` 상태로 남아 있고,
  대상 설비 유형·구역에 `IDLE` 상태인 설비가 전혀 없다
- **WHEN** 디스패치 지연 신호 조회를 요청한다
- **THEN** 해당 업무 오더가 결과에 포함되고 지연 원인에 설비 부족 관련
  표시가 포함된다

#### Scenario: 지연 임계 시간 이내의 업무 오더는 결과에 포함되지 않는다
- **GIVEN** 업무 오더가 `QUEUED` 상태이지만 지연 임계 시간을 아직 넘기지
  않았다
- **WHEN** 디스패치 지연 신호 조회를 요청한다
- **THEN** 그 업무 오더는 결과에 포함되지 않는다

### Requirement: 작업자 다음 행동 안내 조회
시스템은 특정 작업자가 관여한, 아직 종결되지 않은 항목과 각 항목의 유효한 다음 액션을 조회할 수 있어야 한다(SHALL). 조회 결과는 항목의 종류, 현재 상태, 유효한 다음 액션 목록을 포함해야 한다(MUST). 이 조회는 부작용이 없는 읽기 전용이어야 한다(SHALL).

#### Scenario: 작업자가 자신이 검수 중인 입하 건의 다음 행동을 조회한다
- **GIVEN** 작업자 A가 등록한 입하 건이 `RECEIVING` 상태로 남아 있다
- **WHEN** 작업자 A의 다음 행동 안내 조회를 요청한다
- **THEN** 그 입하 건이 결과에 포함되고 유효한 다음 액션(검수 완료 등)이
  함께 반환된다

#### Scenario: 종결된 항목은 다음 행동 안내에 포함되지 않는다
- **GIVEN** 작업자 A가 관여한 입하 건이 이미 `PUTAWAY_COMPLETED` 상태다
- **WHEN** 작업자 A의 다음 행동 안내 조회를 요청한다
- **THEN** 그 입하 건은 결과에 포함되지 않는다

#### Scenario: 관여한 항목이 없는 작업자는 빈 결과를 받는다
- **GIVEN** 작업자 B가 아직 어떤 항목에도 관여하지 않았다
- **WHEN** 작업자 B의 다음 행동 안내 조회를 요청한다
- **THEN** 오류 없이 빈 결과 집합이 반환된다

### Requirement: 자율 실행 판단 근거 기록
시스템은 `PROCESS_AGENT` 역할의 호출자가 이미 다른 계약에서 자율 실행이 허용된 액션을 수행했을 때, 그 판단의 자연어 근거를 기록할 수 있어야 한다(SHALL). 기록은 자연어 근거(`reasoning`)를 필수로 받아야 하며(MUST), 근거가 빈 문자열이면 거부되어야 한다(SHALL NOT 허용). 기록된 판단은 이후 상태가 전이되지 않는 append-only 항목이어야 한다(SHALL).

#### Scenario: 에이전트가 재시도 판단 근거를 기록한다
- **GIVEN** `PROCESS_AGENT`가 지연된 업무 오더에 대해
  `wms_retry_work_order_dispatch`를 이미 호출했다
- **WHEN** 같은 `correlation_id`로 대상 업무 오더와 근거 텍스트를 담아
  판단 기록을 요청한다
- **THEN** `status='LOGGED'`인 판단 레코드가 생성되고 `document_id`가
  반환된다

#### Scenario: 근거 없는 판단 기록은 거부된다
- **GIVEN** `PROCESS_AGENT`가 판단 기록을 요청한다
- **WHEN** `reasoning`이 빈 문자열이다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 허용되지 않은 역할은 판단을 기록할 수 없다
- **GIVEN** 요청자가 `PROCESS_AGENT`도 `WMS_ADMIN`도 아니다
- **WHEN** 판단 기록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 사람 승인이 필요한 제안 생성
시스템은 `PROCESS_AGENT` 역할의 호출자가 자율 실행이 허용되지 않은 조치를 사람이 검토·승인할 수 있는 제안으로 생성할 수 있어야 한다(SHALL). 제안은 제안 유형(`proposal_type`), 자연어 근거(`reasoning`), 제안하는 조치의 구조화된 설명(`proposed_action`)을 필수로 받아야 한다(MUST). 생성된 제안은 `status='PROPOSED'`여야 하며(SHALL), 생성 자체는 다른 어떤 도메인 상태도 변경해서는 안 된다(SHALL NOT).

#### Scenario: 인력 재배치 제안을 생성한다
- **GIVEN** `PROCESS_AGENT`가 인력 작업량 불균형 신호에서 `is_imbalanced=true`
  인 작업자를 확인했다
- **WHEN** `proposal_type='LABOR_REBALANCE'`, 근거와 제안 조치를 담아
  제안 생성을 요청한다
- **THEN** `status='PROPOSED'`인 제안 레코드가 생성되고 `document_id`가
  반환된다

#### Scenario: 제안 조치 없이는 제안을 생성할 수 없다
- **GIVEN** `PROCESS_AGENT`가 제안 생성을 요청한다
- **WHEN** `proposed_action`이 비어 있다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 에이전트 제안 승인
시스템은 `WAREHOUSE_MANAGER`, `WMS_ADMIN` 역할의 사용자가 `status='PROPOSED'`인 에이전트 제안을 승인할 수 있어야 한다(SHALL). 승인은 제안의 `expected_version`을 검증해야 한다(MUST). `PROCESS_AGENT` 역할은 이 승인을 호출할 수 없어야 한다(SHALL NOT). 승인은 제안의 상태만 `CONFIRMED`로 바꿀 뿐, 제안된 조치를 자동으로 실행해서는 안 된다(SHALL NOT).

#### Scenario: 창고 관리자가 제안을 승인한다
- **GIVEN** `status='PROPOSED'`, `version=1`인 제안이 있다
- **WHEN** `WAREHOUSE_MANAGER`가 `expected_version=1`로 승인을 요청한다
- **THEN** 제안의 `status`가 `CONFIRMED`로 바뀌고 `confirmed_by`,
  `confirmed_at`이 기록되며, 다른 어떤 도메인 테이블도 변경되지 않는다

#### Scenario: PROCESS_AGENT는 제안을 승인할 수 없다
- **GIVEN** `status='PROPOSED'`인 제안이 있다
- **WHEN** `PROCESS_AGENT`가 승인을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 이미 처리된 제안은 다시 승인할 수 없다
- **GIVEN** 제안의 `status`가 이미 `CONFIRMED` 또는 `REJECTED`다
- **WHEN** 같은 제안의 승인을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 버전이 어긋나면 승인이 거부된다
- **GIVEN** 제안의 현재 `version=2`다
- **WHEN** `expected_version=1`로 승인을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 제안이 바뀌지 않는다

### Requirement: 에이전트 제안 거부
시스템은 `WAREHOUSE_MANAGER`, `WMS_ADMIN` 역할의 사용자가 `status='PROPOSED'`인 에이전트 제안을 거부할 수 있어야 한다(SHALL). 거부는 사유(`reason`)를 필수로 받아야 하며(MUST), `expected_version`을 검증해야 한다(MUST). `PROCESS_AGENT` 역할은 이 거부를 호출할 수 없어야 한다(SHALL NOT).

#### Scenario: 창고 관리자가 사유를 남기고 제안을 거부한다
- **GIVEN** `status='PROPOSED'`인 제안이 있다
- **WHEN** `WAREHOUSE_MANAGER`가 사유와 올바른 `expected_version`으로
  거부를 요청한다
- **THEN** 제안의 `status`가 `REJECTED`로 바뀌고 `rejected_by`,
  `rejected_at`, `rejection_reason`이 기록된다

#### Scenario: 사유 없는 거부는 거부(rejected)된다
- **GIVEN** `status='PROPOSED'`인 제안이 있다
- **WHEN** `reason` 없이 거부를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: PROCESS_AGENT는 제안을 거부할 수 없다
- **GIVEN** `status='PROPOSED'`인 제안이 있다
- **WHEN** `PROCESS_AGENT`가 거부를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 에이전트 판단·제안 이력 조회
시스템은 테넌트·창고 스코프를 가진 사용자가 기록된 에이전트 판단·제안 이력(`wms.agent_decisions`)을 상태·제안 유형으로 필터링해 조회할 수 있어야 한다(SHALL). 조회 결과는 각 레코드의 `proposal_type`, `reasoning`, `status`, `signals_snapshot`, 생성 시각을 포함해야 한다(MUST). 상태를 갖지 않는 단순 판단(`status='LOGGED'`)과 상태를 갖는 제안(`PROPOSED`/`CONFIRMED`/`REJECTED`) 모두 이 조회로 조회할 수 있어야 한다(SHALL).

#### Scenario: 승인 대기 중인 제안만 필터링해 조회한다
- **GIVEN** 창고에 `LOGGED` 2건, `PROPOSED` 3건인 판단·제안 레코드가 있다
- **WHEN** `status='PROPOSED'`로 필터링해 조회를 요청한다
- **THEN** `PROPOSED` 상태인 3건만 반환된다

#### Scenario: 제안 유형으로 필터링해 조회한다
- **GIVEN** 창고에 `proposal_type='LABOR_REBALANCE'`와
  `proposal_type='EQUIPMENT_ROUTING_SUGGESTION'` 레코드가 섞여 있다
- **WHEN** `proposal_type='LABOR_REBALANCE'`로 필터링해 조회를 요청한다
- **THEN** 해당 유형의 레코드만 반환된다

### Requirement: 자율 실행 범위의 역할 제한
시스템은 이 계약이 새로 정의하는 어떤 RPC도 WMS 원장이나 다른 도메인의 상태를 직접 변경해서는 안 된다(SHALL NOT) — 판단 기록과 제안 생성/승인/거부는 오직 `wms.agent_decisions` 테이블의 상태만 변경해야 한다(SHALL). `PROCESS_AGENT`가 다른 계약에서 이미 자율 실행이 금지된 RPC(예: 구매 승인, 폐기 판정, 장애 해소, 설비 강제 제외, 라우팅 정책 변경)를 호출할 수 있는 권한은 이 계약으로 인해 확장되지 않아야 한다(SHALL NOT).

#### Scenario: 제안 생성이 다른 도메인 테이블을 변경하지 않는다
- **GIVEN** `PROCESS_AGENT`가 인력 재배치 제안을 생성한다
- **WHEN** 제안 생성이 성공한다
- **THEN** `wms.agent_decisions`에만 레코드가 추가되고, 다른 어떤 WMS
  테이블(재고 원장, 업무 오더 등)도 값이 바뀌지 않는다

#### Scenario: 이 계약은 PROCESS_AGENT의 기존 금지 목록을 넓히지 않는다
- **GIVEN** `PROCESS_AGENT`는 `wms_submit_purchase_approval`을 호출할 권한이
  없다(기존 계약)
- **WHEN** 이 계약이 구현된 이후에도 `PROCESS_AGENT`가
  `wms_submit_purchase_approval`을 호출한다
- **THEN** 여전히 `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 테이블(`wms.agent_decisions`)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·명령이 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT).

#### Scenario: 다른 테넌트의 에이전트 판단 이력에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 창고의 에이전트 판단·제안 이력 조회를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환되거나 결과가 비어 있다

#### Scenario: 창고 스코프가 없는 사용자는 제안을 승인할 수 없다
- **GIVEN** 사용자가 제안이 속한 창고에 대한 `warehouse_scopes`를 갖지
  않는다
- **WHEN** 그 창고의 제안 승인을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 판단 기록, 제안 생성·승인·거부를 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름), `entity_type='agent_decision'`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 제안 생성이 감사 이벤트를 남긴다
- **WHEN** 에이전트 제안이 성공적으로 생성된다
- **THEN** `wms.audit_events`에 `command='wms_propose_agent_action'`,
  `entity_type='agent_decision'`인 레코드가 생성된다

#### Scenario: 제안 승인이 감사 이벤트를 남긴다
- **WHEN** 에이전트 제안이 성공적으로 승인된다
- **THEN** `wms.audit_events`에 `command='wms_confirm_agent_proposal'`,
  `entity_type='agent_decision'`인 레코드가 생성되고 `after`에
  `status='CONFIRMED'`가 담긴다
