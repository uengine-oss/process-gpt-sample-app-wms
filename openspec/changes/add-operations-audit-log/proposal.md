## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.4 "감사 기능/확장성", Manhattan
Active WM 절)는 "감사 및 재무 팀은 시스템 내에 자연어로 저장되는 감사 로그
(Audit Log)를 조회하여 AI 에이전트의 판단 근거와 실행 이력을 검증할 수 있다"를
차세대 WMS 플랫폼의 핵심 기능으로 꼽는다. §5 "카탈로그에는 있지만 아직 스펙이
없는 영역" 표는 이 항목을 "`wms_operations-observability`의 확장 후보"로
분류해 두었다.

그러나 실제로 확인해 보면 `wms_operations-observability`는 이 저장소
(`openspec/changes/`, `openspec/specs/`)에 스펙도 구현도 존재하지 않는다 —
§5 표는 이를 main repo(`supabase-wms-erp-replacement`)에 이미 있는 것으로
분류했지만, 그 main repo 자체가 이 저장소에 체크아웃되어 있지 않다. 따라서 이
변경은 존재하지 않는 스펙을 "확장"하는 대신, 이 저장소에 실제로 존재하는
`wms.audit_events` 테이블(`supabase/migrations/20260726_wms_core_schema.sql`)
위에 독립적인 계약으로 자연어 Audit Log 조회 기능을 신설한다.

`wms.audit_events`는 이미 모든 쓰기 RPC가 `command`, `entity_type`,
`entity_id`, `before`/`after` JSONB, `correlation_id`를 구조화해 기록하는
로깅 메커니즘을 갖추고 있다 — 즉 "기록"은 이미 되어 있다. 빠진 것은 (1) 그
구조화된 JSONB를 사람이 스캔하기 쉬운 한국어 문장으로 바꿔 주는 표현 계층과,
(2) 감사자가 기간·행위자·엔티티·명령으로 걸러 조회/내보내기 할 수 있는
목적 지향 쿼리 표면이다. 이 변경은 새 로깅 메커니즘을 만들지 않고, 이 둘만
추가한다.

이 시리즈(11개 영역)의 마지막 영역이며, 이후에 이 영역에 의존하는 후속
스펙은 계획되어 있지 않다.

## What Changes

- 결정론적(non-LLM) 자연어 요약 함수 `wms.describe_audit_event(...)`를
  추가한다 — `command`/`entity_type`/`before`/`after`/(있다면) `reasoning`을
  입력받아 `CASE`/문자열 템플릿으로 한국어 문장을 조립한다. 저장하지 않고
  조회 시점에 계산한다(design.md D1).
- 감사 로그 조회 RPC `wms.wms_query_audit_log`와 내보내기 RPC
  `wms.wms_export_audit_log`를 신설한다 — 기간, 행위자, `entity_type`,
  `entity_id`, `command`, `correlation_id`로 필터링하고 페이지네이션을
  지원하며, 각 행에 `wms.describe_audit_event` 결과를 포함한다.
- `wms.audit_events`에는 어떤 컬럼도 추가하지 않는다. AI 에이전트가 남긴
  판단 근거는 `openspec/changes/add-agentic-operations`(작업 도중 동시에
  생성된 것을 확인)가 소유하는 `wms.agent_decisions.reasoning`을
  `correlation_id`로 조인해 감사 로그 조회 결과에 함께 노출한다(design.md
  D3). 이 조인은 그 변경의 마이그레이션이 먼저 적용된 뒤에만 활성화되는
  2단계 구현으로 분리한다 — 1단계(사람 액터 감사 이벤트의 요약·조회·
  내보내기)는 그 변경과 무관하게 독립적으로 동작한다.
- 조회/내보내기 RPC는 기존 `audit_events_select` RLS(테넌트 스코프, 모든
  테넌트 구성원에게 열려 있음)를 변경하지 않되, 그 위에 `WMS_ADMIN`,
  `AUDITOR` 역할만 호출할 수 있는 추가 역할 게이트를 둔다(design.md D2).
  `AUDITOR`는 기존 스키마 주석(`supabase/migrations/20260726_wms_core_schema.sql`
  30~31행)에 이미 예정된 역할이지만 지금까지 어떤 RPC에서도 실제로 검사되지
  않았다 — 이 변경이 그 역할의 첫 실사용처가 된다.
- 내보내기 RPC 호출 자체를 `wms.audit_events`에 자기 감사(self-audit)
  이벤트로 기록한다 — 누가, 어떤 필터로, 언제 감사 로그를 내보냈는지도
  감사 대상이 된다(design.md D4).
- 이 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/operations/audit-log` 라우트가 추후 이 계약 위에 얹힐 수 있음을
  design.md에 확장 지점으로만 기록한다.
- 데이터베이스 내부에서 LLM을 호출하는 요약 생성은 다루지 않는다(명시적
  제외 범위, design.md 참고).
- `openspec/changes/add-agentic-operations`는 이 변경 작업 도중 다른
  변경으로 생성된 것을 확인했다(최초 확인 시점에는 없었음). 그 변경의
  design.md D5가 이미 "에이전트 판단 근거는 `wms.audit_events`를 확장하지
  않고 companion 테이블 `wms.agent_decisions`로 분리한다"고 결정하고,
  이 계약("자연어 Audit Log")을 자신의 확장 후보로 명시적으로 지목해 두었다
  — 이 변경은 그 경계를 그대로 받아들여 `wms.agent_decisions`를
  `correlation_id`로 조인하는 소비자로만 동작하고, 경쟁하는 스키마를
  제안하지 않는다(design.md D3).
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "자연어 Audit Log"
  행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_operations-audit-log`: `wms.audit_events`에 이미 기록된 구조화된
  쓰기 이력을 결정론적 한국어 문장으로 요약해 제공하고, 감사자/관리자가
  기간·행위자·엔티티·명령·상관관계 ID로 필터링해 조회·내보내기 할 수 있는
  목적 지향 쿼리 표면을 정의하는 WMS 감사(Audit) 계약. 새 로깅 메커니즘을
  만들지 않고 기존 `wms.audit_events`를 조회/표현하는 계층만 추가한다.

### Modified Capabilities

(없음 — 기존 쓰기 RPC의 시그니처·동작을 변경하지 않는다. `wms.audit_events`
스키마 자체도 변경하지 않는다 — 이 변경은 그 위에 조회 전용 함수/RPC만
추가한다.)

## Impact

- **DB**: 신규 SQL 함수 1개(`wms.describe_audit_event`), 신규 RPC 2개
  (`wms.wms_query_audit_log`, `wms.wms_export_audit_log`). 기존 테이블/RPC/
  RLS 정책은 변경하지 않는다 — `wms.audit_events`에 컬럼을 추가하지 않는다
  (design.md D3). `wms.agent_decisions`(`add-agentic-operations` 소유)와의
  조인은 그 변경의 마이그레이션이 적용된 뒤 적용하는 후속 마이그레이션으로
  분리한다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 조회/내보내기 도구 2종을 추가하는
  것은 이 변경의 후속 구현 작업으로 남긴다(tasks.md).
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다.
  `/operations/audit-log` 라우트는 확장 지점으로만 기록한다.
- **역할 모델**: 새 역할을 만들지 않는다 — 기존 스키마 주석에 이미 예정돼
  있었지만 미사용이던 `AUDITOR` 역할을 처음으로 실제 RPC 역할 검사에
  사용하고, `WMS_ADMIN`도 함께 허용한다.
- **다른 영역과의 관계**: 이 저장소에 없는 `wms_operations-observability`를
  확장하는 대신 독립 계약으로 신설한다. `openspec/changes/add-agentic-operations`
  가 소유하는 `wms.agent_decisions`를 `correlation_id`로 조인하는 소비자로만
  동작하고, 경쟁하는 스키마를 제안하지 않는다. 이 시리즈의 11번째이자
  마지막 영역이다 — 이 영역에 의존하는 후속 스펙은 없다.
