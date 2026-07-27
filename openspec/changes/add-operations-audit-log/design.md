## Context

`supabase/migrations/20260726_wms_core_schema.sql`의 `wms.audit_events`
(168~179행)는 이미 모든 쓰기 RPC(`wms_create_rfq`, `wms_submit_purchase_approval`,
`wms_confirm_purchase_order`, `wms_register_arrival`, `wms_receive`,
`wms_record_quality_result`, `wms_apply_disposition`,
`wms_create_putaway_tasks`, 그리고 `20260727_wcs_equipment_control.sql`의
`wms_register_equipment`/`wms_dispatch_equipment_command`/
`wms_report_command_result` 등)가 `command`, `entity_type`, `entity_id`,
`before`, `after`, `correlation_id`를 구조화된 JSONB로 남기는 로깅 메커니즘을
갖추고 있다. RLS도 이미 걸려 있다(`audit_events_select`, 291~292행) — 단,
테넌트 스코프만 검사하고 역할은 검사하지 않는다.

`docs/04-wms-wcs-market-feature-catalog.md` §2.4/§4(Manhattan Active WM 절)는
"감사 및 재무 팀이 자연어로 저장되는 감사 로그를 조회해 AI 에이전트의 판단
근거와 실행 이력을 검증"하는 것을 명시적으로 요구한다. §5 표는 이 항목을
`wms_operations-observability`의 확장 후보로 분류했지만, 직접 확인한 결과
그 스펙은 이 저장소의 `openspec/changes/`, `openspec/specs/` 어디에도 없다
— main repo에만 있다고 표기돼 있으나 main repo 자체가 이 저장소에
체크아웃되어 있지 않다. 따라서 이 설계는 확장이 아니라 신설로 접근한다.

**`openspec/changes/add-agentic-operations`와의 관계(작성 도중 발견).** 이
설계를 작성하는 도중, 동시에 진행 중이던 다른 변경이
`openspec/changes/add-agentic-operations`를 만든 것을 확인했다. 그 변경의
design.md D5는 정확히 이 계약과 맞닿는 결정을 내렸다 — "에이전트 판단·제안은
`wms.audit_events`를 확장하지 않고, 새 companion 테이블
`wms.agent_decisions`로 분리한다"이며, 그 문서는 명시적으로 다음과 같이
경계를 긋는다(인용): *"이 스펙은 **에이전트가 남긴** 판단 근거
(`wms.agent_decisions.reasoning`)만 소유한다. 사람 액터를 포함한 전체 감사
이벤트를 자연어로 검색/요약하는 범용 뷰어는 이 변경의 범위가 아니며, ...
그쪽(자연어 Audit Log) 확장 후보로 명시적으로 남긴다."* — 즉 `add-agentic-operations`
는 이미 이 계약을 자신의 의존 대상으로 지정해 두었다.

이 설계는 그 경계를 그대로 받아들인다: `wms.audit_events`에 `reasoning`
컬럼을 추가하지 않는다(아래 애초 검토했던 대안은 기각 — D3). 대신
`wms.agent_decisions`(존재한다면)를 `correlation_id`로 조인해 에이전트가
남긴 판단 근거를 감사 로그 조회 결과에 함께 노출하는 **소비자**로만
행동한다 — 그 테이블의 소유권, 스키마, 쓰기 RPC는 전적으로
`add-agentic-operations`가 갖는다.

## Goals / Non-Goals

**Goals:**

- `wms.audit_events`의 구조화된 `command`/`entity_type`/`before`/`after`를
  결정론적으로 한국어 문장으로 요약하는 방법을 정의한다.
- 감사자/관리자가 기간·행위자·엔티티·명령·상관관계 ID로 감사 이벤트를
  걸러 조회할 수 있는 목적 지향 RPC를 정의한다(오늘은 원본 테이블 SELECT
  외에 그런 표면이 없다).
- CSV/보고서 생성에 쓸 수 있는 내보내기 RPC를 정의한다.
- 이 계약을 호출할 수 있는 역할을 결정한다.
- AI 에이전트의 판단 근거가 담길 자리를 정의하고, 향후 `add-agentic-operations`
  류의 스펙이 그 자리를 재사용할 수 있도록 관계를 명시한다.

**Non-Goals:**

- **데이터베이스 내부에서의 LLM 호출.** 자연어 요약은 Postgres 함수 안에서
  결정론적 `CASE`/문자열 템플릿으로만 생성한다 — 외부 LLM API를 호출하는
  트리거나 함수는 이 변경에 포함하지 않는다. 이유는 D1 참고.
- **감사 로그 자체의 완전한 BI/리포팅 엔진.** 집계·차트·대시보드는 다루지
  않는다 — 필터링된 행 집합을 반환하는 조회/내보내기 RPC까지만 다룬다.
  실제 CSV 파일 생성이나 리포트 렌더링은 호출자(MCP 도구, 프론트엔드,
  또는 외부 스크립트)의 몫이다.
- **감사 이벤트의 창고(warehouse) 단위 RLS 강제.** `wms.audit_events`에는
  `warehouse_id` 컬럼이 없다(테넌트 단위로만 스코프됨) — 이유와 대안은 D2
  참고.
- **기존 `audit_events_select` RLS 정책 변경.** 원본 테이블에 대한 직접
  SELECT는 계속 모든 테넌트 구성원에게 열려 있다 — 이 변경은 그 정책을
  좁히지 않는다(이유는 D2).
- **에이전트 판단 근거 데이터의 소유.** 판단 근거(`reasoning`)를 누가,
  언제, 어떤 알고리즘으로 만드는지는 `add-agentic-operations`가 소유하는
  `wms.agent_decisions`의 책임이다 — 이 변경은 그 값을 조회해 함께
  보여주는 소비자일 뿐, 생성하거나 소유하지 않는다(D3).
- **`wms.audit_events`에 대한 스키마 확장.** 이 변경은 `wms.audit_events`에
  어떤 컬럼도 추가하지 않는다(D3) — `add-agentic-operations`가 이미 같은
  결론(컬럼 추가 대신 companion 테이블)에 도달했고, 이 변경도 그 결론을
  따른다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 자연어 요약은 조회 시점에 계산되는 Postgres 함수로 만들고, 별도
컬럼에 저장하지 않는다

**검토한 3가지 대안:**

1. **저장형(stored) 요약 컬럼** — 쓰기 RPC가 INSERT 시점에 요약 문장을
   생성해 `wms.audit_events.summary_ko` 같은 컬럼에 함께 저장.
2. **표현 계층(presentation-layer) 계산** — 프론트엔드/MCP 서버가
   `before`/`after`/`command`를 받아 각자 요약 문장을 생성.
3. **읽기 시점 SQL 함수** — `wms.describe_audit_event(...)`를 Postgres
   함수로 만들고, 조회 RPC/뷰가 SELECT 시점에 호출.

**기각 이유:**

- 대안 1(저장형)은 요약 템플릿 로직이 바뀔 때마다(예: 새 명령 추가, 문구
  개선) 과거에 이미 저장된 요약 문장을 다시 백필하는 마이그레이션이
  필요하다 — 이 저장소의 다른 계약들(예: `stock_ledger_entries`는 불변
  원장이라 저장이 맞지만, 요약 문장은 "표현"이지 "사실 기록"이 아니다)과
  성격이 다르다. 또한 새 명령이 추가될 때마다 과거 행의 요약이 비어 있는
  상태로 남는 문제도 생긴다.
- 대안 2(표현 계층)는 유연하지만, 이 저장소가 프론트엔드(Vue)와 MCP 서버
  (Python) 두 소비자를 갖고 있어 같은 템플릿 로직을 두 언어로 중복
  구현해야 한다 — 한쪽만 고치면 두 표면의 문구가 어긋난다.
- 대안 3(읽기 시점 함수)은 두 문제를 모두 피한다: 템플릿 로직을 한 곳
  (`wms` 스키마)에만 두므로 프론트엔드/MCP가 매번 같은 요약을 받고,
  로직을 바꿔도 과거 데이터를 백필할 필요가 없다(다음 SELECT부터 새
  템플릿이 즉시 반영된다). 비용은 저장형보다 약간의 조회 시점 CPU
  뿐이며, `wms.audit_events`의 행 규모(감사 로그는 본질적으로 append-only
  지만 조회는 항상 필터링된 페이지 단위이므로) 이 비용은 무시할 만하다.

**채택: 대안 3.** `wms.describe_audit_event(p_command text, p_entity_type
text, p_before jsonb, p_after jsonb, p_reasoning text default null) returns
text` — `command` 값을 키로 하는 `CASE` 분기로 한국어 문장을 조립한다.
알려지지 않은 `command`(향후 새 RPC가 추가됐지만 아직 이 함수에 분기가
없는 경우)에는 범용 폴백 템플릿(`"{entity_type} 엔티티에 대해 {command}
명령이 실행되었다"` 형태)을 사용해 절대 NULL이나 오류를 내지 않는다 —
그래야 새 명령을 추가할 때마다 이 함수를 갱신하는 것이 요구사항이 아니라
개선 기회가 된다.

이 함수는 **데이터베이스 내부 LLM 호출을 명시적으로 배제**한다(Non-Goal) —
Postgres 함수 안에서 네트워크 호출(HTTP 확장 등)을 하는 것은 트랜잭션
지연·외부 의존성·비용 예측 불가라는 문제를 만들고, 이 샘플 앱의 "그린필드
데모" 스코프와도 맞지 않는다. `CASE`/템플릿 기반 요약은 카탈로그가 요구하는
"자연어로 저장되는 감사 로그 조회"를 결정론적이고 저비용으로 충족한다 —
"저장되는"은 원본 구조화 이벤트가 이미 저장되어 있다는 뜻으로 해석하고,
자연어 문장 자체는 그 위의 조회 시점 표현으로 재해석한다(config.yaml의
"카탈로그 항목을 그대로 베끼지 않고 이 샘플 앱의 실제 스코프에 맞게
재해석" 원칙에 따름).

### D2. 조회/내보내기 RPC는 기존 RLS를 좁히지 않고, 그 위에 역할 게이트를
추가한다 — 창고 단위 스코프는 다루지 않는다

**RLS 현황:** `audit_events_select` 정책은 `tenant_id in (select
wms.current_tenant_ids())`만 검사한다 — 테넌트에 속한 사용자라면 역할과
무관하게 원본 `wms.audit_events` 테이블을 직접 SELECT할 수 있다. 이는 다른
테이블(예: `purchase_orders_select`가 창고 스코프만 검사하고 역할은 쓰기
RPC에서 검사하는 것)과 같은 패턴이다 — 읽기는 넓게 열어 두고, 민감한 동작은
RPC의 역할 검사로 좁힌다.

**결정: 원본 테이블 RLS는 변경하지 않는다.** 다른 스펙(예: 특정 PO의 이력을
보여주는 화면)이 이미 이 넓은 SELECT 권한에 의존하고 있을 수 있고, 이
변경은 그런 기존 사용처를 깨지 않는 것을 우선한다. 대신 `wms_query_audit_log`,
`wms_export_audit_log`는 `SECURITY DEFINER` 함수 안에서
`wms.has_role(p_tenant_id, 'WMS_ADMIN', 'AUDITOR')`를 명시적으로 검사한다
— 카탈로그가 이 기능을 "감사 및 재무 팀" 전용으로 프레이밍하기 때문에,
결정론적 요약과 필터링/내보내기라는 "감사 목적에 특화된 표면"은 일반
테넌트 구성원 전체가 아니라 감사자/관리자로 좁히는 것이 맞다. 원본 테이블
직접 SELECT(요약도 필터링도 없는 raw JSONB)와 이 RPC(요약+필터+내보내기)는
서로 다른 위험 수준을 갖는다고 보고 다르게 게이트한다.

**AUDITOR 역할 재사용:** `supabase/migrations/20260726_wms_core_schema.sql`
30~31행 주석은 "WMS_ADMIN / PROCUREMENT_BUYER / PURCHASE_APPROVER /
INBOUND_OPERATOR / QUALITY_INSPECTOR / AUDITOR / PROCESS_AGENT"를 design.md
§12(main repo)의 전체 역할 목록으로 나열하면서 "(subset used here)"라고
적어 두었다 — 즉 `AUDITOR`는 처음부터 예정돼 있었지만 지금까지 어떤 RPC도
실제로 검사하지 않은 역할이다. `wms.memberships.role`은 자유 텍스트라
새 값을 쓰는 데 마이그레이션이 필요 없다. 이 변경이 `AUDITOR`의 첫 실사용
처가 된다 — 새 역할을 만드는 대신 이미 예정된 역할의 부채를 갚는 선택이다.
`WMS_ADMIN`도 함께 허용해 관리자가 별도로 `AUDITOR` 멤버십을 부여받지
않아도 감사 로그를 조회할 수 있게 한다(다른 계약들의 "`WMS_ADMIN`은 항상
슈퍼셋" 관례와 일관).

**창고 단위 스코프를 다루지 않는 이유:** `wms.audit_events`에는
`warehouse_id` 컬럼이 없다. 억지로 추가하려면 모든 `entity_type`
(`purchase_order`, `receipt`, `equipment`, `dock_appointment`, 심지어
`membership`처럼 창고 개념이 아예 없는 엔티티까지)에 대해 `entity_id`로
연결된 테이블을 조인해 `warehouse_id`를 역산해야 하는데, 이는 매 삽입
시점에 유지하기 취약하고(`entity_type`이 늘어날 때마다 매핑을 갱신해야
함), 삽입 시점에 참조 테이블 행이 아직 존재하지 않는 경우(예: 트랜잭션
안에서 `entity_id`가 방금 생성된 행을 가리키는 경우는 괜찮지만, soft-delete
나 취소된 엔티티는 조인이 끊길 수 있음)도 있다. 테넌트 단위 스코프는
"감사 및 재무 팀이 조직 전체의 판단 이력을 검증"한다는 카탈로그의 실제
요구를 이미 충족한다 — 창고 간 이동을 감사하려는 감사자에게 창고 단위로
결과가 쪼개져 있으면 오히려 불편하다. 대신 조회 RPC는 `p_entity_type`
(예: `'purchase_order'`, `'equipment'`)로 좁히는 것을 창고 단위 좁히기의
실용적 대체 수단으로 제공한다.

### D3. 에이전트 판단 근거는 `wms.agent_decisions`(`add-agentic-operations`
소유)를 `correlation_id`로 조인해 소비하고, `wms.audit_events`에는 어떤
컬럼도 추가하지 않는다

카탈로그(§2.4, Manhattan Active WM 절)는 명시적으로 "AI 에이전트의 판단
근거"를 감사 로그 조회 대상에 포함시킨다. 이 설계를 작성하는 도중,
`openspec/changes/add-agentic-operations`가 동시에 진행 중인 다른 변경으로
생성된 것을 확인했다(§Context). 그 변경의 design.md D5는 정확히 이 문제 —
"에이전트 판단 근거를 어디에 저장할 것인가" — 를 다뤘고, 다음과 같이
결론지었다:

1. **`wms.audit_events`에 `reasoning` 컬럼을 추가한다.**(기각)
2. **새 companion 테이블 `wms.agent_decisions`를 만든다.**(채택)

그 문서가 1안을 기각한 이유(이미 다수 스펙이 `audit_events`에 쓰기를
수행해 컬럼 소유권이 흐려짐, 제안은 `PROPOSED→CONFIRMED/REJECTED` 생명주기를
가져 1회성 사실 기록 모델인 `audit_events`와 성격이 다름)는 이 계약에도
그대로 적용된다. 그러므로 **이 변경은 `wms.audit_events`에 어떤 컬럼도
추가하지 않는다** — 이전 초안에서 검토했던 `reasoning` 컬럼 추가안은
철회한다.

**결정: `wms.agent_decisions.reasoning`을 `correlation_id`로 조인해 감사
로그 조회 결과에 포함한다.** `add-agentic-operations` design.md D5는
"두 테이블은 `correlation_id`로 교차 조인 가능하다"고 명시하고, 에이전트가
자율 실행한 액션은 그 RPC 호출이 만드는 `wms.audit_events` 레코드와 같은
`correlation_id`로 `wms.agent_decisions`(`status='LOGGED'`) 레코드를
남긴다고 설계했다. 이 계약은 정확히 그 조인의 소비자 쪽을 구현한다:

- `wms.wms_query_audit_log`/`wms.wms_export_audit_log`는 반환 행을 만들
  때 `wms.audit_events.correlation_id = wms.agent_decisions.correlation_id`
  로 `LEFT JOIN`해 매칭되는 `reasoning`을 찾고, 그 값을
  `wms.describe_audit_event`의 `p_reasoning` 인자로 전달한다.
- 매칭되는 `wms.agent_decisions` 행이 없으면(사람이 수행한 명령이거나,
  에이전트 액션이지만 아직 판단 근거를 기록하지 않은 경우) `p_reasoning`은
  `NULL`이고, 요약 문장은 판단 근거 문구 없이 생성된다(D1의 함수 시그니처가
  이미 `default null`을 지원하므로 변경 불필요).
- 이 계약은 `wms.agent_decisions`의 스키마, RLS, 쓰기 RPC를 전혀 소유하지
  않는다 — 그 테이블에 대한 어떤 마이그레이션도 이 변경에 포함하지 않는다.

**구현 순서 의존성(중요):** `wms.agent_decisions`를 참조하는 `LEFT JOIN`은
`add-agentic-operations`의 마이그레이션이 먼저 적용된 뒤에만 유효하다 —
그 전에는 해당 테이블이 존재하지 않아 조인 자체가 실패한다. 따라서 이
계약의 구현은 두 단계로 나눈다(tasks.md에 반영):

- **1단계(즉시 가능, core schema만 의존)**: `wms.describe_audit_event`
  (D1), `wms_query_audit_log`, `wms_export_audit_log`, 역할 게이트(D2),
  자기 감사(D4)를 `wms.agent_decisions` 조인 없이 우선 구현한다 — 이
  상태에서도 사람이 수행한 감사 이벤트의 한국어 요약·조회·내보내기는
  완전히 동작한다(카탈로그 요구사항의 "판단 근거" 부분만 비어 있음).
- **2단계(`add-agentic-operations` 마이그레이션 적용 후)**: 위 조인을
  추가하는 후속 마이그레이션 1개를 얹는다 — `wms_query_audit_log`/
  `wms_export_audit_log`의 함수 본문만 `create or replace function`으로
  갱신하고, 시그니처(파라미터/반환 타입)는 바꾸지 않는다. 만약
  `add-agentic-operations`가 끝내 구현되지 않거나 무기한 지연되더라도,
  1단계만으로 이 계약의 나머지 요구사항(요약·조회·내보내기·접근통제)은
  모두 독립적으로 성립한다 — 2단계는 순수 additive 확장이다.

**기각한 대안:** 이 변경이 먼저 `wms.agent_decisions` 유사 테이블을 만들고
`add-agentic-operations`가 나중에 그것을 재사용하도록 요구하는 것. 기각
이유 — `add-agentic-operations`가 이미 그 테이블을 설계·소유하기로 결정한
상태에서 이 변경이 경쟁하는 스키마를 먼저 만드는 것은 지시사항("경쟁 제안을
피하고 참조하라")과도, 두 변경 중 어느 것이 실제로 먼저 구현될지 알 수
없는 상황에서 불필요한 재작업 위험을 만든다는 점과도 맞지 않는다.

### D4. 내보내기(export) 호출 자체를 감사 대상으로 기록한다(자기 감사)

감사 로그를 누가 언제 어떤 조건으로 내보냈는지는 그 자체로 감사·재무팀의
관심사다(예: "누가 지난달 전체 감사 로그를 다운로드했는가"). `wms_export_audit_log`
는 성공적으로 실행될 때마다 `wms.audit_events`에
`command='wms_export_audit_log'`, `entity_type='audit_export'`,
`after`에 사용한 필터 조건(JSONB)을 담은 행을 스스로 추가한다. 이 행도
다음 조회에서 똑같이 `wms.describe_audit_event`로 요약된다("감사자
{actor}가 {기간} 범위의 감사 로그를 내보냈다" 형태) — 별도의 특수 처리
없이 기존 요약 메커니즘을 그대로 재사용한다.

**기각한 대안:** 내보내기를 별도의 `wms.audit_export_log` 테이블에 기록.
기각 이유 — 자기 참조를 위해 새 테이블/RLS/조회 경로를 또 만들 필요 없이,
이미 있는 `wms.audit_events`가 "모든 쓰기의 이력"이라는 정의를 그대로
만족한다(내보내기도 일종의 쓰기 동작으로 취급).

### D5. 내보내기는 페이지네이션 상한 대신 안전 상한(row cap)으로 무제한
추출을 막는다

조회 RPC(`wms_query_audit_log`)는 `p_limit`/`p_offset`으로 명시적
페이지네이션을 요구한다. 내보내기 RPC(`wms_export_audit_log`)는 "필터링된
전체 집합을 한 번에" 받는 것이 목적이므로 페이지네이션을 강제하지 않지만,
안전 상한(예: 최대 10,000행)을 넘는 필터 조건은 `INVALID:` 접두 오류로
거부하고 기간을 좁히도록 안내한다 — 이 샘플 앱은 BI 엔진이 아니므로
무제한 스트리밍/커서 내보내기는 다루지 않는다(Non-Goal).

## Data Model

이 변경은 어떤 테이블 스키마도 만들거나 수정하지 않는다 — `wms.audit_events`
는 기존 그대로(`id, tenant_id, actor_id, command, entity_type, entity_id,
before, after, correlation_id, created_at`) 사용하고, `wms.agent_decisions`
(존재한다면)는 `add-agentic-operations`가 소유한 스키마를 `correlation_id`
로만 조인해 읽는다(D3). 신규 산출물은 아래 SQL 함수와 RPC뿐이다.

### 신규 SQL 함수

`wms.describe_audit_event(p_command text, p_entity_type text, p_before
jsonb, p_after jsonb, p_reasoning text default null) returns text`

- `language sql immutable`(같은 입력에는 항상 같은 출력 — 캐싱/인덱싱에
  유리하며, 이 함수가 부수효과 없는 순수 표현 함수임을 명시).
- `command` 값을 키로 하는 `CASE` 분기(예: `wms_confirm_purchase_order` →
  `"구매 담당자가 발주(PO)를 확정했다"` 형태, `entity_id`/`after`의 구체
  값을 문장에 보간). 최소한 기존 8개 이상의 core 쓰기 명령(§Context 목록)에
  대해 전용 템플릿을 제공한다.
- 알려지지 않은 `command`에는 `"{entity_type} 엔티티에 대해 {command}
  명령이 실행되었다"` 형태의 범용 폴백을 사용한다(D1) — 새 명령이 추가돼도
  요약이 비거나 오류가 나지 않는다.
- `p_reasoning`이 non-null이면 문장 끝에 `"(사유: {reasoning})"`을 덧붙인다.

## RPC 계약 (읽기 전용 — 기존과 동일한 오류 접두 관례: `FORBIDDEN:`/`INVALID:`,
쓰기 부수효과가 없으므로 `expected_version`/`idempotency_key`는 요구하지
않는다. 단 `wms_export_audit_log`는 자기 감사 기록(D4)이라는 쓰기 부수효과가
있으므로 `correlation_id`를 받는다)

| RPC | 역할 | 설명 |
|---|---|---|
| `wms.wms_query_audit_log` | `WMS_ADMIN`, `AUDITOR` | `p_tenant_id`(필수), `p_date_from`, `p_date_to`, `p_actor_id`, `p_entity_type`, `p_entity_id`, `p_command`, `p_correlation_id`(모두 선택), `p_limit`(기본 50, 최대 500), `p_offset`(기본 0)을 받아 필터링된 감사 이벤트를 최신순으로 반환. 각 행에 `wms.describe_audit_event` 결과(`summary_ko`, 2단계 구현 후에는 `wms.agent_decisions` 조인으로 판단 근거 포함)와 전체 매칭 건수(`total_count`, 페이지네이션 UI용)를 포함 |
| `wms.wms_export_audit_log` | `WMS_ADMIN`, `AUDITOR` | `p_tenant_id`(필수), `p_date_from`, `p_date_to`, `p_actor_id`, `p_entity_type`, `p_command`, `p_correlation_id`(모두 선택), `p_correlation_id`는 이번 내보내기 호출 자체의 상관관계 ID로도 사용. 안전 상한(10,000행, D5)을 넘으면 `INVALID:` 오류. 성공 시 필터링된 전체 행(요약 포함)을 반환하고, 호출 자체를 `wms.audit_events`에 자기 감사 이벤트로 기록(D4) |

두 RPC 모두 `SECURITY DEFINER`이며 내부에서 `wms.has_role(p_tenant_id,
'WMS_ADMIN', 'AUDITOR')`를 검사해 실패 시 `FORBIDDEN:`을 반환한다. 원본
`wms.audit_events` 테이블의 `audit_events_select` RLS 정책은 변경하지
않는다(D2) — 두 RPC는 그 위에 추가되는 좁은 게이트다.

## 확장 지점

- **프론트엔드**: `frontend/src/router/index.ts`에 `/operations/audit-log`
  (필터 폼 + 페이지네이션 테이블 + CSV 다운로드 버튼) 라우트를 추가하는
  것은 이 변경에 포함하지 않는다 — `wms_query_audit_log`/`wms_export_audit_log`
  를 소비하는 후속 작업으로 남긴다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 `query_audit_log`,
  `export_audit_log` 도구를 추가하는 것은 후속 구현 작업(tasks.md)으로
  남긴다 — `PROCESS_AGENT`는 이 두 도구의 허용 목록에 포함하지 않는다(D2의
  역할 게이트가 이미 `WMS_ADMIN`/`AUDITOR`로 좁혀 두므로, 에이전트가 감사
  로그를 스스로 조회하는 것은 이 변경의 범위 밖 — 감사자가 에이전트의
  행동을 감시하는 방향만 다룬다).
- **`add-agentic-operations`와의 관계**: 이 설계 작성 도중 그 change
  디렉터리가 실제로 생겼음을 확인했다(D3). 이 계약은 그 변경이 소유하는
  `wms.agent_decisions`를 `correlation_id`로 조인하는 소비자로만 행동하며,
  그 마이그레이션이 적용된 뒤에만 조인 기능이 활성화된다(2단계 구현, D3).
  그 변경이 스키마를 바꾸면(예: `reasoning` 대신 `reasoning_ko`로 컬럼명이
  바뀌는 등) 이 계약의 조인 쿼리만 갱신하면 되고, `wms_query_audit_log`/
  `wms_export_audit_log`의 외부 시그니처는 영향받지 않는다.
- **`wms_operations-observability`와의 관계**: 이 저장소에 그 스펙이 실제로
  생기면(현재는 없음), 이 계약(`wms_operations-audit-log`)은 그 스펙이
  다루는 "실시간 설비/작업 상태 모니터링"과는 별개로 남는다 — 전자는
  "지금 무엇이 일어나고 있는가", 후자는 "과거에 무엇이 왜 일어났는가"를
  다루는 서로 다른 시간축의 계약이다.
