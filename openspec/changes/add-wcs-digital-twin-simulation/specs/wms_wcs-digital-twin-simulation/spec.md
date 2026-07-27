# WCS 디지털 트윈/시뮬레이션 계약

## Purpose

실제 자동화 하드웨어 없이 `wms_wcs-equipment-control`의 설비 명령 계약을
실제로 이행할 수 있도록, 시뮬레이션 대상으로 표시된 설비에 대해 디스패치된
명령을 현실적인 타이밍과 실패/잼 주입 확률에 따라 자동으로 진행시키는
소프트웨어 시뮬레이터 계약을 정의한다. 시스템은 설비별 타이밍/실패율
프로파일을 등록·조회할 수 있어야 하고, 각 명령의 진행 계획을 재시작 안전하게
저장해야 하며, 그 진행이 `wms_wcs-equipment-control`의 실제 명령 결과 보고
경로를 통해서만 이루어지도록 해야 한다 — 이를 통해 그 계약과 그 위에 얹힌
후속 계약들의 검증·전파 로직이 시뮬레이션 환경에서도 동일하게 동작한다. 이
계약은 또한 설비 구성 변경이 예상 완료 소요시간에 미치는 영향을 같은 타이밍
모델로 추정하는, 범위를 명시적으로 좁힌 what-if 시나리오 dry-run을 제공한다
— 이 추정은 실제 명령을 디스패치하지 않는 순수 산술 근사치이며, 3D 모션·물리
시뮬레이션이 아니다.

## ADDED Requirements

### Requirement: 설비 시뮬레이션 모드 지정
시스템은 창고 범위 안의 설비에 대해 시뮬레이션 대상 여부(`is_simulated`)를 지정할 수 있어야 한다(SHALL). 이 지정은 설비의 `expected_version`을 검증해야 한다(MUST). 시뮬레이션 모드 지정은 `wms_wcs-equipment-control`이 정의하는 설비의 다른 어떤 상태(`status`, 진행 중 명령)도 변경하지 않아야 한다(SHALL NOT).

#### Scenario: 설비를 시뮬레이션 모드로 전환한다
- **GIVEN** `is_simulated=false`인 설비가 있다
- **WHEN** 올바른 `expected_version`으로 `is_simulated=true` 지정을 요청한다
- **THEN** 그 설비의 `is_simulated`가 `true`로 바뀌고, 설비의 `status`는
  변경되지 않는다

#### Scenario: 버전이 어긋나면 지정이 거부된다
- **GIVEN** 설비의 현재 `version=3`이다
- **WHEN** `expected_version=2`로 시뮬레이션 모드 지정을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 `is_simulated` 값이 바뀌지 않는다

### Requirement: 시뮬레이션 프로파일 등록과 갱신
시스템은 `is_simulated=true`인 설비에 대해 단계별 지연 시간 범위(승인 지연, 진행 지연, 완료 지연)와 실패 확률(`failure_rate`), 잼 조건부 확률(`jam_rate`)을 등록할 수 있어야 한다(SHALL). `is_simulated=true`가 아닌 설비에 대한 프로파일 등록은 거부해야 한다(SHALL NOT). 이미 프로파일이 등록된 설비에 대한 중복 등록은 거부해야 한다(SHALL NOT). 프로파일 갱신은 프로파일의 `expected_version`을 검증해야 한다(MUST).

#### Scenario: 시뮬레이션 대상 설비에 프로파일을 등록한다
- **GIVEN** `is_simulated=true`인 설비에 아직 프로파일이 없다
- **WHEN** 지연 범위와 `failure_rate=0.1`로 프로파일 등록을 요청한다
- **THEN** 프로파일이 `status='ACTIVE'`로 생성되고 그 설비에 연결된다

#### Scenario: 시뮬레이션 대상이 아닌 설비에는 프로파일을 등록할 수 없다
- **GIVEN** 설비의 `is_simulated=false`다
- **WHEN** 그 설비에 프로파일 등록을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 이미 프로파일이 있는 설비에 다시 등록할 수 없다
- **GIVEN** 설비에 이미 `ACTIVE` 프로파일이 있다
- **WHEN** 같은 설비에 프로파일 등록을 다시 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 버전이 어긋나면 프로파일 갱신이 거부된다
- **GIVEN** 프로파일의 현재 `version=2`이다
- **WHEN** `expected_version=1`로 갱신을 요청한다
- **THEN** `CONFLICT:` 접두 오류가 반환되고 프로파일이 바뀌지 않는다

### Requirement: 시뮬레이션 프로파일 조회와 기본값 대체
시스템은 테넌트·창고 범위 안의 설비별 시뮬레이션 프로파일을 조회할 수 있어야 한다(SHALL). `is_simulated=true`이지만 등록된 프로파일이 없거나 프로파일이 `status='INACTIVE'`인 설비에 대해서는, 조회 결과에 시스템 기본 타이밍/실패율 값이 적용된 것으로 표시해야 한다(SHALL) — 프로파일 부재가 시뮬레이션 자체를 막지 않는다.

#### Scenario: 등록된 프로파일이 조회된다
- **GIVEN** 설비에 `failure_rate=0.2`인 프로파일이 등록되어 있다
- **WHEN** 그 설비의 프로파일 조회를 요청한다
- **THEN** `failure_rate=0.2`를 포함한 등록된 값이 반환된다

#### Scenario: 프로파일이 없는 시뮬레이션 대상 설비는 시스템 기본값으로 조회된다
- **GIVEN** 설비의 `is_simulated=true`이고 등록된 프로파일이 없다
- **WHEN** 그 설비의 프로파일 조회를 요청한다
- **THEN** 시스템 기본 타이밍/실패율 값이 반환되고, 그 값이 등록된 프로파일이
  아니라 기본값임이 표시된다

### Requirement: 시뮬레이션 명령 계획 수립
시스템은 `is_simulated=true`인 설비에 디스패치된, 아직 계획이 없는 명령에 대해 진행 계획(각 단계의 목표 시각, 최종 결과, 결과 payload)을 수립할 수 있어야 한다(SHALL). 계획은 등록된 프로파일 또는 시스템 기본값의 지연 범위와 확률을 사용해 수립되어야 한다(MUST). 이미 계획이 있는 명령에 대해 계획 수립을 다시 요청하면 새 계획을 만들지 않고 기존 계획을 그대로 반환해야 한다(SHALL) — 멱등. `is_simulated=true`가 아닌 설비의 명령에 대한 계획 수립은 거부해야 한다(SHALL NOT).

#### Scenario: 새 명령에 대해 계획이 수립된다
- **GIVEN** `is_simulated=true`인 설비에 `PENDING` 명령이 있고 아직 계획이
  없다
- **WHEN** 그 명령의 계획 수립을 요청한다
- **THEN** `next_status='ACKNOWLEDGED'`와 미래의 `next_run_at`을 포함한 계획이
  생성된다

#### Scenario: 이미 계획된 명령은 다시 계획되지 않는다
- **GIVEN** 명령에 이미 진행 계획이 있다
- **WHEN** 같은 명령의 계획 수립을 다시 요청한다
- **THEN** 새 계획이 생성되지 않고 기존 계획이 그대로 반환된다

#### Scenario: 시뮬레이션 대상이 아닌 설비의 명령은 계획할 수 없다
- **GIVEN** 명령이 디스패치된 설비의 `is_simulated=false`다
- **WHEN** 그 명령의 계획 수립을 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 대기 중인 시뮬레이션 액션 조회
시스템은 실행 시각(`next_run_at`)이 도래한 진행 계획을 조회할 수 있어야 한다(SHALL). 조회 결과는 도래 시각 오름차순으로 정렬되어야 한다(MUST). 아직 도래하지 않은 계획은 결과에 포함되지 않아야 한다(SHALL NOT).

#### Scenario: 도래한 계획만 반환된다
- **GIVEN** 계획 A의 `next_run_at`이 이미 지났고, 계획 B의 `next_run_at`은
  미래다
- **WHEN** 대기 중인 시뮬레이션 액션 조회를 요청한다
- **THEN** 계획 A만 반환되고 계획 B는 반환되지 않는다

#### Scenario: 여러 건이 도래하면 시각 순으로 정렬된다
- **GIVEN** 도래한 계획이 세 건이고 각각 도래 시각이 다르다
- **WHEN** 대기 중인 시뮬레이션 액션 조회를 요청한다
- **THEN** 결과가 도래 시각 오름차순으로 정렬되어 반환된다

### Requirement: 시뮬레이션 명령 진행 보고
시스템은 도래한 진행 계획에 대해 다음 단계 상태를 `wms_wcs-equipment-control`의 명령 결과 보고 경로로 실제 보고해야 한다(SHALL). 종결 상태(`COMPLETED`/`FAILED`)가 아닌 단계를 보고한 뒤에는 계획을 다음 단계로 갱신해야 한다(SHALL). 종결 상태를 보고한 뒤에는 그 명령의 진행 계획을 제거해야 한다(SHALL). 아직 도래하지 않았거나 계획이 없는 명령에 대한 진행 보고 요청은 거부해야 한다(SHALL NOT).

#### Scenario: 중간 단계 진행이 보고되고 계획이 갱신된다
- **GIVEN** 계획의 `next_status='ACKNOWLEDGED'`이고 도래 시각이 지났다
- **WHEN** 그 명령의 진행 보고를 요청한다
- **THEN** 명령이 `ACKNOWLEDGED`로 보고되고, 계획의 `next_status`가
  `IN_PROGRESS`로, `next_run_at`이 다음 목표 시각으로 갱신된다

#### Scenario: 종결 단계가 보고되면 계획이 제거된다
- **GIVEN** 계획의 `next_status='COMPLETED'`이고 도래 시각이 지났다
- **WHEN** 그 명령의 진행 보고를 요청한다
- **THEN** 명령이 `COMPLETED`로 보고되고, 그 명령의 진행 계획이 더 이상
  조회되지 않는다

#### Scenario: 도래하지 않은 계획은 진행 보고가 거부된다
- **GIVEN** 계획의 `next_run_at`이 아직 미래다
- **WHEN** 그 명령의 진행 보고를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환되고 명령 상태가 바뀌지 않는다

### Requirement: 명령 타입별 결과 payload 어휘 매핑
시스템은 계획 수립 시점에 명령의 `command_type`에 따라 결과 payload의 어휘를 선택해야 한다(SHALL) — 슈트 라우팅 명령은 성공/오분류/잼 어휘를, 혼합 팔레타이징 명령은 성공/부분 적재/중량 초과/용적 초과/중단과 항목별 적재 결과 배열 어휘를 사용해야 한다(SHALL). 그 외의 명령 타입에는 일반 성공/실패 어휘를 사용해야 한다(SHALL).

#### Scenario: 슈트 라우팅 명령은 라우팅 결과 어휘로 계획된다
- **GIVEN** `command_type='DIVERT'`인 명령이 계획 대상이다
- **WHEN** 그 명령의 계획이 수립된다
- **THEN** 계획된 결과 payload가 성공/오분류/잼 중 하나의 결과 값을 갖는다

#### Scenario: 혼합 팔레타이징 명령은 항목별 적재 결과 어휘로 계획된다
- **GIVEN** `command_type='PALLETIZE'`이고 서열 항목 목록을 담은 명령이
  계획 대상이다
- **WHEN** 그 명령의 계획이 수립된다
- **THEN** 계획된 결과 payload가 각 서열 항목에 대응하는 적재 결과 배열을
  포함한다

#### Scenario: 알려지지 않은 명령 타입은 일반 결과 어휘로 계획된다
- **GIVEN** `command_type='MOVE'`인 명령이 계획 대상이다
- **WHEN** 그 명령의 계획이 수립된다
- **THEN** 계획된 결과 payload가 일반 성공/실패 결과 값을 갖는다

### Requirement: 시뮬레이션 대상이 아닌 설비의 배제
시스템은 `is_simulated=false`인 설비에 디스패치된 명령에 대해서는 어떤 진행 계획도 수립하거나 자동으로 보고하지 않아야 한다(SHALL NOT) — 그런 명령의 상태 전이는 실제 게이트웨이 또는 사람 운영자의 몫으로 남아야 한다(SHALL).

#### Scenario: 시뮬레이션 대상이 아닌 설비의 명령은 자동 진행되지 않는다
- **GIVEN** 설비의 `is_simulated=false`이고 그 설비에 `PENDING` 명령이 있다
- **WHEN** 대기 중인 시뮬레이션 액션 조회를 요청한다
- **THEN** 그 명령에 대한 계획이 결과에 포함되지 않는다

### Requirement: what-if 시나리오 정의
시스템은 설비 집합과 처리할 것으로 가정하는 명령 건수를 지정해 what-if 시나리오를 정의할 수 있어야 한다(SHALL). 시나리오는 선택적으로 참고용 상위 엔티티 참조(`linked_entity_type`/`linked_entity_id`)를 가질 수 있다(MAY). 설비 집합이 비어 있거나 명령 건수가 0 이하이면 시나리오 정의를 거부해야 한다(SHALL NOT).

#### Scenario: 유효한 설비 집합과 건수로 시나리오를 정의한다
- **WHEN** 설비 2대와 `command_count=10`으로 시나리오 정의를 요청한다
- **THEN** 시나리오가 `status='DRAFT'`로 생성된다

#### Scenario: 설비 집합이 비어 있으면 정의가 거부된다
- **WHEN** 빈 설비 집합으로 시나리오 정의를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

#### Scenario: 명령 건수가 0 이하이면 정의가 거부된다
- **WHEN** `command_count=0`으로 시나리오 정의를 요청한다
- **THEN** `INVALID:` 접두 오류가 반환된다

### Requirement: 시나리오 실행과 예상 타임라인 산출
시스템은 정의된 시나리오를 실행해, 시나리오가 지정한 설비 집합의 프로파일(또는 시스템 기본값)을 사용한 예상 완료 시점과 예상 실패 건수를 산출할 수 있어야 한다(SHALL). 이 실행은 어떤 실제 설비 명령도 디스패치하지 않아야 한다(SHALL NOT). 같은 시나리오는 여러 번 실행할 수 있어야 하며(SHALL), 각 실행 결과는 별개의 실행 이력으로 저장되어야 한다(MUST). 실행 결과에는 기본값이 적용된 설비가 있는 경우 이를 알리는 경고가 포함되어야 한다(MUST).

#### Scenario: 시나리오 실행이 예상 완료 시점을 산출한다
- **GIVEN** 설비 2대(각 프로파일 등록됨)와 `command_count=10`인 시나리오가
  있다
- **WHEN** 그 시나리오 실행을 요청한다
- **THEN** `projected_completion_at`, `projected_round_count`,
  `projected_failure_count`를 포함한 실행 결과가 생성되고, 어떤
  `wms.equipment_commands` 레코드도 새로 생성되지 않는다

#### Scenario: 프로파일이 없는 설비가 포함되면 경고가 포함된다
- **GIVEN** 시나리오에 포함된 설비 중 하나에 등록된 프로파일이 없다
- **WHEN** 그 시나리오 실행을 요청한다
- **THEN** 실행 결과가 산출되고, `warnings`에 기본값이 적용되었음을 알리는
  값이 포함된다

#### Scenario: 같은 시나리오를 다시 실행하면 별개의 실행 이력이 남는다
- **GIVEN** 시나리오가 이미 한 번 실행되어 실행 이력 1건이 있다
- **WHEN** 같은 시나리오를 다시 실행한다
- **THEN** 실행 이력이 2건이 되고, 기존 실행 이력은 변경되지 않는다

### Requirement: 테넌트·창고 단위 접근 통제
시스템은 이 계약의 모든 테이블(시뮬레이션 프로파일, 진행 계획, 시나리오, 시나리오 실행 이력)에 대해 사용자가 속한 테넌트와, `wms.current_warehouse_ids()`로 판별되는 창고 스코프 안에서만 조회·명령이 가능하도록 강제해야 한다(SHALL). 모든 쓰기는 `SECURITY DEFINER` RPC를 통해서만 이루어져야 하며, 테이블에 대한 직접 `INSERT`/`UPDATE`/`DELETE` 권한은 `authenticated` 역할에 부여되지 않아야 한다(SHALL NOT).

#### Scenario: 다른 테넌트의 시뮬레이션 프로파일에는 접근할 수 없다
- **GIVEN** 사용자가 테넌트 A에 속해 있다
- **WHEN** 테넌트 B 소유 설비의 시뮬레이션 프로파일 등록을 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

#### Scenario: 허용되지 않은 역할은 명령 진행 보고를 수행할 수 없다
- **GIVEN** 요청자가 `WCS_GATEWAY` 역할이 아니다
- **WHEN** 시뮬레이션 명령 진행 보고를 요청한다
- **THEN** `FORBIDDEN:` 접두 오류가 반환된다

### Requirement: 감사 추적
시스템은 시뮬레이션 모드 지정, 프로파일 등록·갱신, 시나리오 정의·실행을 포함한 모든 쓰기 작업을 기존 `wms.audit_events` 테이블에 기록해야 한다(SHALL). 각 감사 레코드는 `command`(RPC 이름), `entity_type`, `entity_id`, 변경 전/후 상태(`before`/`after`), `correlation_id`를 포함해야 한다(MUST).

#### Scenario: 프로파일 등록이 감사 이벤트를 남긴다
- **WHEN** 시뮬레이션 프로파일이 성공적으로 등록된다
- **THEN** `wms.audit_events`에 `command='wms_register_simulation_profile'`,
  `entity_type='simulation_profile'`인 레코드가 생성된다

#### Scenario: 시나리오 실행이 감사 이벤트를 남긴다
- **WHEN** 시나리오가 성공적으로 실행된다
- **THEN** `wms.audit_events`에 `entity_type='simulation_scenario_run'`인
  레코드가 생성된다
