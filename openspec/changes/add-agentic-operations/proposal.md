## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.4, §4 Manhattan Active WM)는 차세대
WMS/WES 제품의 핵심 차별점으로 **에이전틱 AI**를 꼽는다 — Wave Coordinator
Agent(웨이브 미출고 원인 자율 분석·교정), Labor Agent(인력 불균형 탐지·재배치),
Associate Agent(작업자 온디바이스 가이던스). §5는 이 영역을 "ProcessGPT 자체가
에이전트 오케스트레이션을 담당하므로 매핑 방식 논의 필요"라고 미결 상태로
남겨 뒀다. 이 변경은 그 논의를 결론짓는다.

**핵심 설계 결정 (먼저 명시)**: Manhattan Active WM 같은 실제 벤더는 자율
에이전트를 WMS 제품 내부에 내장한다 — WMS 자신이 언제 에이전트를 호출할지
결정하고, 에이전트가 WMS 데이터에 직접 작용한다. 그러나 이 저장소의 제품은
이미 모든 에이전트 오케스트레이션·자율 판단·Human-in-the-loop 워크플로우를
ProcessGPT(별도의, 훨씬 더 정교한 BPM+에이전트 플랫폼)에 위임한 상태다
(`docs/03-processgpt-integration.md`) — 이 WMS는 ProcessGPT 테넌트에 등록되는
streamable-HTTP MCP 서버(`wms-mcp`)의 도구 제공자일 뿐이며, `PROCESS_AGENT`라는
service identity가 그 도구를 통해 WMS RPC를 호출한다. BPMN 프로세스 순서 결정,
LLM 판단 루프, HITL 폼 렌더링은 전부 ProcessGPT 쪽 책임이고 이 저장소는 그것을
소유하지 않는다.

따라서 **이 스키마 안에 두 번째 에이전트 오케스트레이션 엔진을 만들지
않는다.** 대신 이 변경은 Manhattan Active WM류 에이전트가 실제로 하는 일
(웨이브 지연 교정, 인력 불균형 재배치, 작업자 가이던스)을 **ProcessGPT
쪽에서 실행되는 외부 에이전트가 대신 수행할 수 있도록**, WMS가 노출해야 하는
(1) 관찰 신호(읽기 RPC), (2) 자율 실행 가능한/사람 승인이 필요한 액션의 명확한
경계, (3) "에이전트가 무엇을 보고 왜 그렇게 판단했는지"를 사람이 검토할 수
있는 판단·제안 로그, 이 세 가지 계약만 정의한다. Wave Coordinator Agent와
Labor Agent는 각각 아직 DB에 구현되지 않은 `wms_wes-material-flow-control` +
`wms_wcs-bottleneck-routing`, 그리고 `wms_labor-management`(모두 스펙은
완료됐지만 마이그레이션은 없음)의 신호를 소비하므로, 이 변경은 그 의존성을
숨기지 않고 명시적으로 밝힌다(design.md "정직한 전제 확인").

**작성 도중 확인한 두 동시 진행 변경과의 조율**: 이 문서를 작성하는 동안
같은 카탈로그 §5의 다른 행을 다루는 `add-labor-management`
(`wms_labor-management`)와 `add-operations-audit-log`
(`wms_operations-audit-log`)가 함께 완료됐다. 전자는 이 변경이 처음
설계했던 "인력 불균형" 최소 프록시 신호를 정확한 생산성 집계로 대체할 수
있게 했다(design.md D2). 후자는 이 변경과 정확히 같은 문제("에이전트 판단
근거를 어디에 저장할 것인가")를 검토했고, 두 변경이 서로의 최신 설계를
다시 확인한 끝에 이 변경이 원래부터 갖고 있던 결론(companion 테이블
`wms.agent_decisions`가 소유, `wms.audit_events`는 컬럼을 추가하지 않음)
으로 수렴했다 — `wms_operations-audit-log`는 그 테이블을 `correlation_id`
로 `LEFT JOIN`해 소비하는 쪽에 스스로를 위치시켰다(design.md D5).

## What Changes

- `wms` 스키마(기존과 동일 schema/인스턴스, 동일 RLS/RPC 봉투 규약)에 에이전트
  판단·제안 기록용 신규 companion 테이블 `wms.agent_decisions`를 추가한다.
  기존 `wms.audit_events`는 스키마를 변경하지 않는다 — "에이전트가 왜 그렇게
  판단했는가"라는 자연어 근거와 제안→승인/거부 생명주기는 `audit_events`의
  1회성 사실 기록 모델과 맞지 않기 때문이다(design.md D5). 동시에 진행된
  `wms_operations-audit-log`도 같은 결론에 도달해 이 테이블을
  `correlation_id`로 조인해 소비하기로 확정했다(design.md D5, 상호 검토).
- 신규 읽기 전용 RPC 4종을 추가한다: 인력 작업량 불균형 신호
  (`wms_get_labor_balance_signals`, `wms_labor-management`의
  `wms_get_labor_productivity`를 감싸 창고 전체 편차를 계산 — 그 변경의
  마이그레이션 이후에만 실제로 값을 냄), 디스패치 지연 신호
  (`wms_get_dispatch_delay_signals`, `wms_wes-material-flow-control`와
  `wms_wcs-bottleneck-routing` 구현 이후에만 실제로 값을 낼 수 있음 — 의존성
  명시), 작업자 다음 행동 안내(`wms_get_worker_next_actions`, 기존 core
  schema 기반으로 오늘 구현 가능), 판단·제안 이력 조회
  (`wms_get_agent_decisions`, `wms.agent_decisions`만 의존).
- 신규 쓰기 RPC 4종을 추가한다: 자율 실행 판단 근거 기록
  (`wms_log_agent_decision`, `wms.agent_decisions`에 `status='LOGGED'`로
  기록 — core schema만 의존, 오늘 구현 가능), 사람 승인이 필요한 제안 생성
  (`wms_propose_agent_action`), 제안 승인(`wms_confirm_agent_proposal`,
  `PROCESS_AGENT` 명시적 거부), 제안 거부(`wms_reject_agent_proposal`,
  `PROCESS_AGENT` 명시적 거부).
- 새 액션 실행 RPC를 만들지 않는다 — 제안이 승인되어도 시스템이 자동으로
  그 액션을 실행하지 않는다(design.md D7, Non-Goal). 실제 조치는 사람이 직접
  하거나, 별도 ProcessGPT BPMN 스텝이 기존에 이미 허용된 RPC(예:
  `wms_retry_work_order_dispatch`)를 명시적으로 호출한다 —
  `wms_submit_purchase_approval` 패턴과 동일하게 승인은 상태 전이일 뿐이다.
- `mcp/wms_mcp/mcp_server.py`에 위 8개 RPC를 감싸는 `@mcp.tool` 함수를
  추가한다. `wms_confirm_agent_proposal`/`wms_reject_agent_proposal`은
  `PROCESS_AGENT` 허용 목록에서 제외한다.
- `docs/03-processgpt-integration.md`의 "에이전트 tool 허용 목록"에 이 변경의
  읽기 4종 + `wms_log_agent_decision` + `wms_propose_agent_action` 6개 도구를
  추가하는 것을 후속 작업으로 tasks.md에 남긴다(이 변경 자체는 `docs/03`을
  직접 수정하지 않는다 — 다른 영역 작업과의 동시 편집 충돌을 피하기 위해
  tasks.md 항목으로만 기록).
- 새 service role은 추가하지 않는다 — 기존 `PROCESS_AGENT`,
  `WAREHOUSE_MANAGER`, `WMS_ADMIN`을 재사용한다. 단, `wms_get_labor_balance_signals`
  는 `PROCESS_AGENT`에게 창고 전체 비교 신호를 명시적으로 허용한다 — 그
  RPC가 감싸는 `wms_get_labor_productivity`의 "본인 행만" 프라이버시 규칙과는
  다른, 이 신호 하나에 한정된 의도적 예외다(design.md D2).
- 카탈로그의 "인력 관리"(생산성 측정·수요예측·게이미피케이션, `wms_labor-management`
  가 이미 별도로 다룸), "감사 로그의 자연어 요약·조회·내보내기"(`wms_operations-audit-log`
  가 이미 별도로 다룸), "디스패치 지연 교정의 실제 자동 실행", 병목 라우팅
  정책 변경 자체는 이번 변경에 포함하지 않는다 — 이 변경은 신호 노출·제안
  계약·판단 근거 기록만 제공한다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "에이전틱 AI" 행을
  스펙 완료로 갱신하고, "매핑 방식 논의 필요" 메모를 이 변경의 결론으로
  대체한다.

## Capabilities

### New Capabilities

- `wms_agentic-operations`: ProcessGPT 쪽에서 실행되는 외부 에이전트(Wave
  Coordinator/Labor/Associate 유사 역할)가 WMS 운영 신호를 조회하고, 자율
  실행이 허용된 범위 안에서는 기존 RPC를 직접 호출하며, 그 범위를 벗어나는
  조치는 사람이 검토·승인/거부할 수 있는 제안으로만 생성하고, 모든 판단의
  근거(자연어 reasoning)를 사람이 감사할 수 있도록 기록하는 계약. WMS 안에
  자율 오케스트레이션 엔진을 두지 않으며, ProcessGPT가 계속 오케스트레이터
  역할을 한다.

### Modified Capabilities

(없음 — 기존 `wms_wes-material-flow-control`, `wms_wcs-bottleneck-routing`의
스펙 문구나 역할 모델을 바꾸지 않는다. `PROCESS_AGENT`가 이미 허용된 RPC
[`wms_retry_work_order_dispatch` 등]는 그대로 재사용하고, 이미 거부된 RPC
[`wms_exclude_equipment_from_routing`, `wms_submit_purchase_approval` 등]도
그대로 거부 상태를 유지한다 — 이 변경은 그 경계를 재확인만 한다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 1종(`wms.agent_decisions`, 판단+제안
  모두), 신규 RPC 8종(읽기 4, 쓰기 4), 신규 RLS 정책 추가. 기존
  `20260726_wms_core_schema.sql`은 변경하지 않는다. 2개 RPC만 다른 미구현
  변경에 의존한다 — `wms_get_dispatch_delay_signals`는
  `wms_wes-material-flow-control` + `wms_wcs-bottleneck-routing`,
  `wms_get_labor_balance_signals`는 `wms_labor-management`에 의존한다(둘
  다 스펙은 완료됐지만 마이그레이션은 아직 없음). 나머지 6개 RPC(판단
  기록·제안 생성·승인·거부 4종 + `wms_get_worker_next_actions` +
  `wms_get_agent_decisions`)는 오늘의 core schema만으로 구현 가능하다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 8종 추가. 기존 도구는
  변경하지 않는다.
- **문서**: `docs/03-processgpt-integration.md`의 에이전트 tool 허용 목록
  갱신을 tasks.md 후속 작업으로 남긴다. `docs/04-wms-wcs-market-feature-catalog.md`
  §5 "에이전틱 AI" 행 갱신.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/agent/proposals`(사람 검토 대기 중인 에이전트 제안 목록) 라우트가 추후
  이 계약 위에 얹힐 수 있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: 변경 없음(기존 역할 재사용). `PROCESS_AGENT`는 제안 생성·
  판단 근거 기록·모든 읽기 RPC(`wms_get_labor_balance_signals` 포함, 의도적
  확장)는 가능하지만, 제안 승인/거부는 명시적으로 금지된다(사람 전용).
- **후속 영역**: `wms_labor-management`가 구현되면
  `wms_get_labor_balance_signals`가, `wms_wes-material-flow-control` +
  `wms_wcs-bottleneck-routing`이 구현되면 `wms_get_dispatch_delay_signals`가
  각각 실제로 값을 내기 시작한다 — 이 변경의 RPC 시그니처와 스펙 문구는
  바뀌지 않는다. `wms_operations-audit-log`가 구현되면 그 계약의 감사 로그
  조회가 이 계약의 `wms.agent_decisions`를 조인해 자연어 요약에 판단
  근거를 포함시키기 시작한다(이 계약의 스키마·RPC는 바뀌지 않음).
