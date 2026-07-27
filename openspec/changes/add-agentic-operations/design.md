## Context

`docs/04-wms-wcs-market-feature-catalog.md`(§2.4, §4)가 정리한 Manhattan Active
WM의 에이전틱 AI는 세 가지 역할로 구성된다: Wave Coordinator Agent(웨이브
미출고 원인 자율 분석·교정), Labor Agent(인력 불균형 감지·재배치), Associate
Agent(작업자 온디바이스 가이던스). 같은 카탈로그는 "AI 판단 이력의 자연어
Audit Log 조회"도 같은 절에서 함께 다룬다. §5는 이 영역의 매핑 방식을
"ProcessGPT 자체가 에이전트 오케스트레이션을 담당하므로 논의 필요"로 미결
상태로 남겼다.

### 아키텍처 비교와 이 변경의 결정

| | Manhattan Active WM (실제 벤더) | 이 저장소의 제품 |
|---|---|---|
| 에이전트가 사는 곳 | WMS 제품 프로세스 내부(MSA 서비스) | ProcessGPT(별도 BPM+에이전트 플랫폼) |
| 언제 에이전트를 호출할지 결정 | WMS 자신 | ProcessGPT의 BPMN 프로세스/폴링 |
| 자율 판단(LLM 추론) | WMS 내부 | ProcessGPT 내부 (`services/completion`) |
| HITL 승인 UI | WMS 통합 UX | ProcessGPT의 HITL 폼 |
| WMS가 제공하는 것 | 없음(에이전트 자체가 WMS) | 신호(읽기 RPC/뷰)·액션(RPC)·감사 로그 |

`docs/03-processgpt-integration.md`가 실측한 대로, 이 제품은 이미 이 패턴을
일부 구현하고 있다 — `wms-mcp`가 ProcessGPT 테넌트의 `tenants.mcp`에
streamable-HTTP 서버로 등록되고, `PROCESS_AGENT`가 허용된 도구 목록
(`wms.get_availability`, `wms.create_rfq`, `wms.dispatch_equipment_command`
등)만 호출하며, 구매 승인·품질 판정 같은 HITL 스텝은 ProcessGPT의 폼과
`wms_submit_purchase_approval`(사람 전용 RPC)로 처리된다. **이 변경은 새
아키텍처를 도입하는 것이 아니라, 이미 존재하는 이 패턴을 "웨이브 지연 교정 ·
인력 불균형 재배치 · 작업자 가이던스"라는 세 가지 새 도메인으로 확장하는
것이다.**

### 세 에이전트 역할의 구체적 매핑 (§5의 미결 논의를 여기서 결론짓는다)

- **Wave Coordinator Agent** → ProcessGPT에서 실행되는 에이전트가
  `wms_get_dispatch_delay_signals`(이 변경, 신규)와
  `wms_get_equipment_routing_status`(`wms_wcs-bottleneck-routing`, 기존
  계약)를 주기적으로 호출해 지연·병목을 관찰한다. 이미 `PROCESS_AGENT`에게
  허용된 액션(`wms_retry_work_order_dispatch` 등)은 에이전트가 직접 호출해
  자율 교정하되, `wms_log_agent_decision`으로 판단 근거를 남긴다. 설비 강제
  제외·라우팅 정책 변경처럼 이미 사람 전용으로 막혀 있는 액션은
  `wms_propose_agent_action`으로 제안만 만든다.
- **Labor Agent** → `wms_get_labor_balance_signals`(이 변경, 신규)로 작업량
  불균형을 관찰한다. 이 신호는 `wms_labor-management`(스펙 완료, DB 미구현)
  의 생산성 집계(`wms_get_labor_productivity`)를 감싸 창고 전체의 작업자 간
  편차를 계산한다(D2). `wms_labor-management`가 실행 가능한 재배치 RPC까지는
  아직 정의하지 않았으므로, 이 에이전트의 모든 조치는
  `wms_propose_agent_action`을 통한 **제안뿐**이다 — 사람이 검토 후 수동으로
  조치하거나, 향후 재배치 RPC가 생기면 그 경로로 이어진다.
- **Associate Agent** → 새 WMS 계약을 거의 필요로 하지 않는다. 기존 RPC 봉투가
  이미 모든 쓰기 응답에 `next_actions`를 포함하고(`docs/02-contracts.md`
  §9.2 인용 관례), ProcessGPT의 HITL 폼이 이미 그 값을 사람에게 보여주는
  통로다. 이 변경은 여기에 `wms_get_worker_next_actions`(신규, 읽기 전용)만
  더해 "이 작업자가 지금 처리해야 할 항목 요약"을 한 번에 조회할 수 있게
  한다 — 나머지(자연어로 풀어 설명하는 것, 온디바이스 UI)는 ProcessGPT/
  프론트엔드의 책임으로 남는다.

### 정직한 전제 확인 (구현 상태와 의존성의 성격)

- **`wms_wes-material-flow-control`, `wms_wcs-bottleneck-routing` 모두 아직
  구현되지 않았다.** `supabase/migrations/`에 해당 마이그레이션이 없다.
  `wms_get_dispatch_delay_signals`가 참조하는 `wms.work_orders`,
  `wms.dispatch_waves`, `wms.wcs_equipment_bottleneck_status`는 그 두
  변경의 design.md에 있는 **검토용 후보**이며 실제 DB에는 존재하지 않는다.
  이 RPC는 그 두 변경이 구현된 뒤에만 실제로 값을 낼 수 있다 —
  구현하더라도 컴파일(마이그레이션 적용)조차 되지 않는다는 점을 tasks.md에
  명시한다.
- **이 변경의 실제 DB 의존성은 대부분 core schema(이미 구현됨)에만 있다.**
  `wms.agent_decisions` 테이블, `wms_log_agent_decision`,
  `wms_propose_agent_action`, `wms_confirm_agent_proposal`,
  `wms_reject_agent_proposal`, `wms_get_agent_decisions`,
  `wms_get_worker_next_actions` 6개는 오늘 당장 `20260726_wms_core_schema.sql`
  위에 마이그레이션할 수 있다. `wms_get_labor_balance_signals`,
  `wms_get_dispatch_delay_signals` 2개만 아래에서 설명하는 선행 변경에
  의존한다 — tasks.md에서 이 2개 RPC를 별도 장으로 분리한다.

### 작성 도중 확인한 두 동시 진행 변경 (교차 검토)

이 문서를 작성하는 도중, 같은 카탈로그 §5의 다른 미결 행을 다루는 두 변경이
동시에 진행되어 완료된 것을 확인했다 — `add-labor-management`
(`wms_labor-management`)와 `add-operations-audit-log`
(`wms_operations-audit-log`). 둘 다 이 변경과 직접 맞닿는 결정을 내렸으므로,
이 문서는 처음 작성한 가정을 그 결과에 맞춰 갱신했다:

- **`add-labor-management`가 이미 인력 활동 로그(`wms.labor_activities`)와
  생산성 집계 RPC(`wms_get_labor_productivity`, `wms_get_labor_leaderboard`,
  `wms_forecast_labor_demand`)를 정의했다.** 애초 이 문서는 "정식 인력 관리
  도메인은 스펙조차 없다"는 전제로 `wms.audit_events`의 `actor_id`만 세는
  최소 프록시를 설계했으나, 그 전제가 더 이상 사실이 아니다. 아래 D2를
  그 계약을 소비하는 방향으로 다시 썼다. 단, `wms_labor-management`도
  `supabase/migrations/`에 마이그레이션이 없는 **미구현** 상태다 — 따라서
  `wms_get_labor_balance_signals`는 `wms_get_dispatch_delay_signals`와 같은
  종류의 "선행 변경 미구현" 의존성을 갖는다(정직하게 명시).
- **`add-operations-audit-log`도 이 계약과 같은 문제("에이전트 판단 근거를
  어디에 저장할 것인가")를 다뤘다.** 그 변경은 처음에 `wms.audit_events`에
  `reasoning` 컬럼을 추가하는 안을 검토했으나, 최종적으로는 그 안을
  철회하고 **이 계약이 소유하는 `wms.agent_decisions`를 `correlation_id`로
  `LEFT JOIN`해 소비하는 쪽**으로 확정했다(그 변경의 design.md D3) — 즉
  `wms.audit_events`에는 어떤 컬럼도 추가되지 않는다. 이 문서가 한때 그
  철회 전 초안(컬럼 재사용)에 맞춰 설계를 바꿨던 적이 있으나, 두 변경이
  서로의 최신 상태를 다시 확인한 뒤 최종적으로는 **이 계약이 처음부터
  갖고 있던 설계(상태 없는 판단도 `wms.agent_decisions`가 소유)가 두
  계약이 함께 수렴한 결론**이 되었다. 아래 D5는 이 최종 상태를 반영한다.
  `wms_operations-audit-log`의 `wms_query_audit_log`/`wms_export_audit_log`
  는 `wms.audit_events.correlation_id = wms.agent_decisions.correlation_id`
  로 `LEFT JOIN`해 `status='LOGGED'`인 레코드의 `reasoning`을 자연어 요약에
  포함시킨다(소비자 쪽 구현은 그 변경의 책임) — 이 계약은 그 조인이 가능한
  형태(`status`, `reasoning`, `correlation_id` 컬럼)로 테이블을 유지하기만
  하면 된다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블/RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

## Goals / Non-Goals

**Goals:**

- ProcessGPT에서 실행되는 외부 에이전트가 "웨이브 지연", "인력 불균형",
  "설비 병목"을 감지할 수 있는 읽기 신호 계약.
- 작업자에게 "다음에 뭘 해야 하는지"를 안내하는 데 필요한 최소 조회 계약
  (Associate Agent가 소비할 재료).
- 이미 존재하거나 예정된 쓰기 RPC 중 어떤 것을 `PROCESS_AGENT`가 **직접**
  호출해도 되는지(자율 실행), 어떤 것은 **제안만** 만들고 사람이 승인해야
  하는지를 명확히 하는 허용/거부 목록.
- 에이전트의 판단·제안에 자연어 근거(reasoning)를 남겨 사람이 "왜 이 판단을
  했는가"를 감사할 수 있게 하는 계약 — 사람이 만든 감사 이벤트와 구분되는
  형태로, 그리고 `wms_operations-audit-log`의 통합 자연어 감사 조회가 그
  근거를 함께 보여줄 수 있는 형태로.
- 후속 도메인(정식 인력 관리, 웨이브/병목 신호가 실제로 채워지는 시점)이 이
  계약을 다시 만들지 않고 그 위에 얹을 수 있는 확장 지점.

**Non-Goals:**

- **DB 안의 ML 모델.** 병목·불균형 판정은 이미 다른 스펙(`wms_wcs-bottleneck-routing`,
  `wms_labor-management`)이 정의한 계산을 그대로 재사용한다. 예측 모델을
  Postgres 함수로 구현하지 않는다.
- **Postgres 안에서 도는 자율 스케줄링 루프.** 이 변경은 신호를 "조회"하고
  판단을 "기록"하는 RPC만 제공한다 — pg_cron 등으로 주기적으로 스스로
  판단하고 액션을 실행하는 백그라운드 잡을 만들지 않는다. "언제 관찰할지"는
  전적으로 ProcessGPT(BPMN 타이머 이벤트 또는 폴링)가 결정한다.
- **두 번째 BPM 엔진.** 프로세스 순서, 조건 분기, 사람 승인 대기 같은
  오케스트레이션 로직을 이 스키마 안에 만들지 않는다 — ProcessGPT가 계속
  유일한 오케스트레이터다.
- **제안의 자동 실행.** `wms_confirm_agent_proposal`은 제안의 상태만
  `CONFIRMED`로 바꾼다. 그 확인이 실제로 대응하는 RPC 호출(예: 인력 재배치
  RPC, 설비 강제 제외 RPC)을 자동으로 트리거하지 않는다 — 동적 RPC 디스패치
  엔진은 그 자체로 "자율 실행 루프"이므로 만들지 않는다(D7).
- **정식 인력 관리 도메인 자체(생산성 측정, 수요 예측, 게이미피케이션, 실제
  재배치 실행).** `wms_labor-management`(스펙 완료, DB 미구현)의 몫이다.
  이 변경은 그 계약의 생산성 집계를 감싸 "불균형 여부"라는 비교 신호 하나만
  더할 뿐, 생산성 데이터 자체를 다시 만들지 않는다(D2).
- **디스패치 지연/병목 판정 로직 자체의 재구현.** `wms_wes-material-flow-control`,
  `wms_wcs-bottleneck-routing`이 이미 정의했거나 정의할 판정 로직을 이
  변경이 다시 만들지 않는다 — 그 결과를 읽어 하나의 조회 계약으로 묶어
  제공할 뿐이다.
- **감사 로그의 결정론적 자연어 요약, 필터링·내보내기 표면.** 이는
  `wms_operations-audit-log`(스펙 완료, DB 미구현)가 이미 소유한
  `wms.describe_audit_event`, `wms_query_audit_log`, `wms_export_audit_log`
  의 몫이다 — 이 변경은 그 계약이 `wms.agent_decisions`를 조인해 소비할 수
  있는 형태로 데이터를 유지할 뿐, 요약/조회/내보내기 로직 자체를 다시
  만들지 않는다(D5).
- 프론트엔드 화면 구현.

## Decisions

### D1. 신호는 새 사실 테이블이 아니라 읽기 전용 RPC로 노출한다

`wms_wcs-bottleneck-routing`이 뷰(`create view`)로 신호를 노출한 것과 달리,
이 변경은 처음부터 **RPC**로 노출한다. 이유: `wcs-bottleneck-routing`의 뷰도
결국 MCP 도구로 노출하려면 그 뷰를 감싸는 RPC(`wms_get_equipment_routing_status`)
를 별도로 만들었다 — MCP 도구는 함수 호출 기반이라 뷰를 직접 노출할 수
없기 때문이다. 이 변경의 신호는 처음부터 MCP 노출이 목적이므로 뷰 단계를
생략하고 바로 `security definer` RPC로 시작한다. 내부 구현에서 뷰를 쓸지
직접 쿼리를 쓸지는 구현 세부이며, 이 문서는 강제하지 않는다.

### D2. 인력 불균형 신호는 `wms_labor-management`의 생산성 집계를 감싸는 창고 전체 뷰로 계산한다 — 새 프록시를 만들지 않는다

`add-labor-management`가 이미 이 저장소에 "작업자가 언제부터 언제까지 어떤
업무를 처리했는가"를 기록하는 인력 활동 로그(`wms.labor_activities`)와
작업자별·역할별 생산성 집계 RPC(`wms.wms_get_labor_productivity`)를
정의했다(그 계약의 design.md D1은 `wms.audit_events` 타임스탬프 역산 방식을
"행위자 모호성·유휴시간 오염" 문제로 이미 기각하고, 명시적 시작/완료 RPC
쌍으로 정확한 처리 시간을 계측하기로 결정했다). 이 변경이 처음 작성한
"`actor_id` 커맨드 건수 세기" 프록시는 그보다 정확도가 훨씬 낮으므로, 그
계약이 존재하는 지금은 그것을 다시 만들지 않는다 — **중복 구현을 피하고
`wms_get_labor_productivity`를 그대로 감싼다.**

`wms_get_labor_balance_signals(p_tenant_id, p_warehouse_id, p_period_start,
p_period_end)`는 내부적으로 `wms.wms_get_labor_productivity`와 동일한 집계
쿼리를 창고 전체 스코프로 호출해(관리자 뷰), 작업자별 `completed_count`의
평균 대비 편차 비율과 `is_imbalanced`를 계산해 반환한다. `wms_labor-management`
의 생산성 계약 자체(활동 유형 분류, 처리 시간, 수량 등)를 다시 정의하지
않는다 — 오직 "누가 상대적으로 많이/적게 처리하고 있는가"라는 비교 결과만
얹는다.

**역할 확장이 필요한 이유**: `wms_get_labor_productivity`는 그 계약의 D3
(개인정보 이중 통제)에 따라 비관리자 호출자에게는 본인 행만 반환한다 —
그러나 "인력 불균형 감지"는 본질적으로 여러 작업자를 비교해야 하는 질문이라
`PROCESS_AGENT`가 자신의 행만 보면 아무 의미가 없다. 따라서
`wms_get_labor_balance_signals`는 `WAREHOUSE_MANAGER`/`WMS_ADMIN`뿐 아니라
`PROCESS_AGENT`도 창고 전체 편차 비교 결과를 볼 수 있도록 명시적으로
허용한다(아래 RPC 계약, 역할 모델). 이 확장은 의도적으로 좁다 — 원본 생산성
로그(`wms.labor_activities` 개별 행)나 리더보드(`wms_get_labor_leaderboard`)
에 대한 `PROCESS_AGENT` 접근권을 넓히는 것이 아니라, 이 신호 RPC 하나에만
한정된다. 또한 이 신호를 보고 실제로 재배치를 실행할 권한은 여전히 없다
(D6) — 볼 수 있는 것과 실행할 수 있는 것을 분리했으므로, 접근권 확장이
곧 통제력 확장을 뜻하지 않는다.

**정직한 의존성**: `wms_labor-management`도 이 문서 작성 시점 기준 스펙만
완료되었을 뿐 DB에는 구현되지 않았다(`supabase/migrations/`에 해당
마이그레이션 없음). 따라서 `wms_get_labor_balance_signals`는
`wms_get_dispatch_delay_signals`(D3)와 같은 종류의 "선행 변경 미구현"
의존성을 갖는다 — tasks.md에서 이 두 RPC를 함께 별도 장으로 분리한다.

**대안으로 고려했으나 기각한 것**: "`wms_labor-management`가 구현될 때까지
이 신호 자체를 만들지 않는다"도 가능했다. 하지만 그러면 Labor Agent 매핑이
공백으로 남는다. `wms_wcs-bottleneck-routing`이 스스로도 미구현인
`wms_wcs-equipment-control` 위에 설계를 진행한 선례(D3와 동일)를 따라, 이
신호도 "선행 계약의 예정된 모양"에 맞춰 지금 설계해 둔다.

### D3. 디스패치 지연 신호는 미구현 스펙의 예정된 모양에 맞춰 설계하되, 마이그레이션 순서로 의존성을 명시한다

`wms_wcs-bottleneck-routing`이 스스로 아직 구현되지 않은
`wms_wcs-equipment-control`의 스키마를 근거로 설계를 진행한 선례를 따른다.
`wms_get_dispatch_delay_signals`는 `wms_wes-material-flow-control`의
`wms.work_orders`(`status='QUEUED'`인 상태로 일정 시간 이상 머무른 레코드)와
`wms_wcs-bottleneck-routing`의 `wms.wcs_equipment_bottleneck_status`를 조인해
"이 웨이브/구역이 왜 지연되고 있는가"(가용 설비 부족인지, 병목 때문인지)를
함께 보여준다. 이 RPC의 마이그레이션은 두 선행 변경의 마이그레이션이 모두
적용된 뒤에만 적용 가능하다 — tasks.md에서 `wms_get_labor_balance_signals`
(D2)와 함께 별도 장으로 분리해, 나머지 6개 RPC(core schema만 의존)와
착수 시점을 분리한다.

### D4. Associate 가이던스는 새 개념을 만들지 않고 기존 `next_actions` 관례 + 최소 조회 RPC로 충분하다고 판단한다

Manhattan Active WM의 Associate Agent는 "작업자 온디바이스 가이던스"를
제공한다. 이 저장소에서 그 역할은 이미 부분적으로 채워져 있다 — 모든 쓰기
RPC가 `{result, document_id, status, version, next_actions, warnings?}`
봉투로 응답하고(`docs/02-contracts.md` §9.2), ProcessGPT의 HITL 폼이 그
값을 사람에게 보여준다. 이 변경은 여기에 새 쓰기 계약을 더하지 않고,
읽기 전용 `wms_get_worker_next_actions(p_tenant_id, p_warehouse_id,
p_actor_id)` 하나만 추가한다 — 그 작업자가 최근 관여한(actor_id로 식별)
아직 종결되지 않은 `wms.receipts`(예: `RECEIVING`, `QC_PENDING` 상태)를
모아 각각의 유효한 다음 액션을 요약해 반환한다. "자연어로 친절하게
설명하는 것"과 "온디바이스 UI에 표시하는 것"은 ProcessGPT/프론트엔드가
할 일이며, 이 RPC는 그 재료(구조화된 데이터)만 제공한다.

이 RPC는 core schema(`wms.receipts`)만 의존하므로 오늘 구현 가능하다. 후속
확장 지점으로, `wms_wes-material-flow-control`이 구현되면 `wms.work_orders`
기반 항목도 같은 RPC의 결과 집합에 합쳐질 수 있다(RPC 시그니처는 바뀌지
않고 내부 쿼리만 확장) — 이번 변경은 그 확장을 하지 않는다.

### D5. 에이전트 판단·제안은 `wms.audit_events`를 확장하지 않고, 하나의 companion 테이블 `wms.agent_decisions`가 상태 없는 판단과 상태를 갖는 제안을 함께 소유한다

두 가지 대안을 검토했다:

1. **`wms.audit_events`에 `reasoning` 컬럼을 추가한다.**
2. **새 테이블 `wms.agent_decisions`를 만들고, 판단(상태 없음)과 제안
   (상태 있음)을 모두 이 테이블이 소유한다.**(채택)

1안을 기각한 이유:

- `wms.audit_events`는 이미 구현되어 있고, 이 저장소의 거의 모든 스펙이
  그 테이블에 쓰기를 수행한다. 이미 다수의 다른 스펙이 소유권을 나눠 갖고
  있는 테이블에 이 변경만의 필요로 컬럼을 얹는 것은 "누가 이 컬럼을 채울
  책임이 있는가"를 흐리게 한다 — 사람이 만든 감사 이벤트 대부분은
  `reasoning`이 항상 `null`일 것이기 때문이다.
- `wms.audit_events`는 "한 번 기록되면 끝"인 1회성 사실 기록 모델이다.
  그러나 에이전트의 **제안**(Labor Agent의 재배치 제안 등)은
  `PROPOSED → CONFIRMED/REJECTED`라는 자체 생명주기를 가진다 — 이는
  이 저장소의 다른 상태 기계형 엔티티(`wms.rfqs`, `wms.wcs_routing_overrides`)
  가 따르는 "자기 테이블 + `version`" 패턴에 가깝다. "지금 이 제안이 승인
  대기 중인가"를 낙관적 동시성과 함께 직접 질의하려면 자신의 테이블이
  필요하다.

2안을 채택한 이유는 위 두 문제를 모두 피한다는 것이다 — `wms.agent_decisions`
는 이 변경만 소유하는 테이블이므로 누가 채우는지 명확하고(오직
`PROCESS_AGENT`/`WMS_ADMIN`), 상태 기계(`LOGGED`/`PROPOSED`/`CONFIRMED`/
`REJECTED`)로 제안 생명주기와 상태 없는 단순 판단 로그를 함께 자연스럽게
표현한다. 두 종류를 같은 테이블에 두는 이유는 둘 다 "에이전트의 판단
근거"라는 같은 열람 대상이고, 별도 테이블로 쪼개면 `wms_get_agent_decisions`
같은 조회 RPC가 두 테이블을 조인해야 하는 불필요한 복잡도가 생기기
때문이다 — 대신 `status` 값으로 두 종류를 구분한다(`LOGGED`는 상태 전이가
없는 append-only 항목, `PROPOSED`는 `CONFIRMED`/`REJECTED`로 전이).

**`wms_operations-audit-log`와의 관계(수렴 확인)**: 이 스펙과 동시에 진행된
`add-operations-audit-log`도 정확히 같은 문제("에이전트 판단 근거를 어디에
저장할 것인가")를 검토했고, 위와 동일한 이유로 `wms.audit_events`에 컬럼을
추가하는 안을 최종적으로 기각했다(그 변경의 design.md D3). 대신 그 계약의
`wms_query_audit_log`/`wms_export_audit_log`가 `wms.audit_events.correlation_id
= wms.agent_decisions.correlation_id`로 `LEFT JOIN`해 `status='LOGGED'`인
레코드의 `reasoning`을 자연어 요약에 포함시키는 **소비자**로 스스로를
위치시켰다 — 이 테이블의 스키마·RLS·쓰기 RPC는 전적으로 이 계약이 소유한다.
따라서 `wms.agent_decisions`는 `status`, `reasoning`, `correlation_id`
컬럼을 그 조인이 성립하는 형태로 유지해야 한다(아래 데이터 모델) — 이는
이미 이 테이블의 원래 설계와 정확히 일치하므로 추가 조정이 필요 없다.

**"자연어 Audit Log" 카탈로그 항목의 경계**: 이 스펙은 **에이전트가 남긴**
판단 근거(`wms.agent_decisions.reasoning`)를 생성·소유한다. 사람 액터를
포함한 전체 감사 이벤트를 자연어로 검색/요약/필터링/내보내기 하는 표면은
`wms_operations-audit-log`의 `wms.describe_audit_event`,
`wms_query_audit_log`, `wms_export_audit_log`가 담당한다 — 이 계약은 그
RPC들을 다시 만들지 않는다.

### D6. 자율 실행 가능한 액션과 제안만 가능한 액션을 명시적으로 구분한다

기존 스펙들이 이미 세운 원칙(`docs/03-processgpt-integration.md`의 tool
허용 목록, `wms_wcs-bottleneck-routing` D5의 "임계값 조정·강제 제외는 사람의
운영 판단")을 그대로 재사용하고, 이번에 새로 생기는 액션에도 같은 원칙을
적용한다.

| 상황(신호) | `PROCESS_AGENT`가 자율 실행 가능 | 사람 승인이 필요(제안만 가능) |
|---|---|---|
| 디스패치 지연(웨이브/업무 오더 재시도) | `wms_retry_work_order_dispatch`(기존, `wms_wes-material-flow-control`에서 이미 `PROCESS_AGENT` 허용) 직접 호출 + `wms_log_agent_decision`으로 근거 기록 | — |
| 병목 설비 강제 제외·라우팅 정책 변경 | — (기존 결정 유지, 변경하지 않음) | `wms_exclude_equipment_from_routing`, `wms_register_wcs_routing_policy` 등은 여전히 `PROCESS_AGENT` 거부. 대신 `wms_propose_agent_action(proposal_type='EQUIPMENT_ROUTING_SUGGESTION')`로 제안만 생성 |
| 인력 작업량 불균형 재배치 | — (실행 RPC 자체가 존재하지 않음 — `wms_labor-management`는 아직 재배치 RPC를 정의하지 않음) | `wms_propose_agent_action(proposal_type='LABOR_REBALANCE')`로 제안만 생성. 사람이 검토 후 수동 조치(향후 재배치 RPC가 생기면 그 경로로 대체) |
| 작업자 가이던스 조회 | `wms_get_worker_next_actions` 등 모든 읽기 RPC는 부작용이 없으므로 항상 자유롭게 호출 가능 | 해당 없음 |
| 판단 근거 기록 | `wms_log_agent_decision`(`wms.agent_decisions`에 `status='LOGGED'`로 기록, 상태 변경 없는 append-only, D5) | 해당 없음 |
| 제안 생성 | `wms_propose_agent_action`(제안 생성 자체는 `wms.agent_decisions`에 `status='PROPOSED'` 행을 만들 뿐 실행이 아님) | 해당 없음 |
| 제안 승인/거부 | — (명시적으로 거부) | `wms_confirm_agent_proposal`, `wms_reject_agent_proposal`은 `WAREHOUSE_MANAGER`/`WMS_ADMIN` 전용. `PROCESS_AGENT` 호출 시 `FORBIDDEN:` |
| 구매 승인(`wms_submit_purchase_approval`), 폐기 판정(`wms_apply_disposition`), 장애 해소(`wms_resolve_equipment_fault`) | — (변경 없음) | 기존과 동일하게 계속 사람 전용 — 이 변경은 그 경계를 재확인만 하고 바꾸지 않는다 |

원칙: **에이전트가 자율 실행할 수 있는 액션은 항상 "이미 다른 스펙이
`PROCESS_AGENT`에게 명시적으로 허용한 RPC"의 부분집합으로만 한정한다.** 이
변경 자신은 새로운 자율 실행 RPC를 만들지 않는다 — 새로 생기는 쓰기 RPC
(판단 기록, 제안 생성/승인/거부)는 전부 "기록"이거나 "사람 승인 게이트"일
뿐, WMS 원장이나 다른 도메인 상태를 직접 바꾸지 않는다.

### D7. 제안 승인은 상태 전이일 뿐, 자동 실행을 트리거하지 않는다

`wms_confirm_agent_proposal`은 `wms.agent_decisions.status`를 `PROPOSED`에서
`CONFIRMED`로 바꿀 뿐이다. `proposed_action`(jsonb에 담긴, 제안된 조치의
설명)을 실제로 실행하는 RPC를 동적으로 찾아 호출하는 디스패치 로직을 만들지
않는다. 이유는 Non-Goals와 동일 — 그런 동적 실행 엔진은 그 자체로 Postgres
안의 "자율 스케줄링 루프"이며, 이 변경이 피하려는 아키텍처(두 번째 오케스트레이션
엔진)를 재도입하는 것과 같다. 대신 `wms_submit_purchase_approval` 패턴을
그대로 따른다 — 승인은 상태 플래그일 뿐이고, 그 다음 실제 조치(RPC 호출)는
사람이 프론트엔드에서 직접 하거나, ProcessGPT의 다음 BPMN 스텝이 이미 존재하는
RPC를 명시적으로 호출한다.

## 데이터 모델 (검토용 후보)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은 구현 단계에서
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`은 수정하지 않는다.

### `wms.agent_decisions` — 에이전트 판단·제안 로그

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` | `uuid` | FK `wms.tenants` |
| `warehouse_id` | `uuid` | FK `wms.warehouses` |
| `proposal_type` | `text` | 열린 집합(다른 스펙의 `work_order_type` 등과 동일 패턴). 이번 변경이 쓰는 값: `DISPATCH_RETRY`(LOGGED 전용), `LABOR_REBALANCE`, `EQUIPMENT_ROUTING_SUGGESTION`(둘 다 PROPOSED 전용) |
| `target_entity_type` | `text` | 이 판단/제안이 가리키는 대상의 종류(예: `'work_order'`, `'equipment'`, `'actor'`), nullable |
| `target_entity_id` | `uuid` | 대상 엔티티 id, nullable |
| `signals_snapshot` | `jsonb` | 판단/제안 시점에 조회한 신호 RPC의 결과를 그대로 보존(재현 가능성을 위해), nullable |
| `reasoning` | `text` | 자연어 판단 근거, 필수(빈 문자열 불허) — `wms_operations-audit-log`가 `correlation_id`로 조인해 소비한다(D5) |
| `proposed_action` | `jsonb` | `status='PROPOSED'`일 때만 채움(필수) — 제안하는 조치의 구조화된 설명(호출해야 할 RPC 이름, 파라미터 후보 등). 사람이 참고용으로만 쓰며 시스템이 자동 실행하지 않는다(D7). `LOGGED`에는 채우지 않는다(null) |
| `status` | `text` | `LOGGED \| PROPOSED \| CONFIRMED \| REJECTED` |
| `confirmed_by` / `confirmed_at` | `uuid` / `timestamptz` | nullable, `CONFIRMED` 전이 시 채움 |
| `rejected_by` / `rejected_at` / `rejection_reason` | `uuid` / `timestamptz` / `text` | nullable, `REJECTED` 전이 시 채움 |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | 관련된 `wms.audit_events` 레코드(자율 실행 시)와 교차 조인용 — `wms_operations-audit-log`가 이 컬럼으로 `LEFT JOIN`한다(D5) |
| `created_at` / `created_by` | | `created_by`는 대개 `PROCESS_AGENT` 아이덴티티 |
| `updated_at` / `updated_by` | | |

`status='LOGGED'`는 `wms_log_agent_decision`으로만 생성되고 그 이후 상태
전이가 없다(append-only). `status='PROPOSED'`는 `wms_propose_agent_action`
으로 생성되고 `CONFIRMED`/`REJECTED`로만 전이한다 — `LOGGED`↔`PROPOSED` 간
전환은 없다(둘은 서로 다른 생성 RPC가 만드는 서로 다른 항목이다).

## RPC 계약 (검토용 시그니처 초안)

모든 RPC는 기존과 동일하게 `language plpgsql security definer set search_path =
wms, public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only)를 따른다.

### 읽기 신호 RPC

| RPC | 주요 파라미터 | 의존성 | 비고 |
|---|---|---|---|
| `wms_get_labor_balance_signals` | `p_tenant_id, p_warehouse_id, p_period_start default now() - interval '1 day', p_period_end default now()` | `wms_labor-management`(스펙 완료, DB 미구현) | `wms.wms_get_labor_productivity`를 창고 전체 스코프로 호출해 작업자별 `completed_count`의 평균 대비 편차 비율과 `is_imbalanced`를 계산(D2) |
| `wms_get_dispatch_delay_signals` | `p_tenant_id, p_warehouse_id, p_wave_id default null` | `wms_wes-material-flow-control` + `wms_wcs-bottleneck-routing`(둘 다 미구현) | `wms.work_orders`(`QUEUED` 상태로 지연 임계 초과)와 `wms.wcs_equipment_bottleneck_status`를 조인해 지연 원인(설비 부족/병목)을 함께 반환(D3) |
| `wms_get_worker_next_actions` | `p_tenant_id, p_warehouse_id, p_actor_id` | core schema만(오늘 구현 가능) | 해당 작업자가 관여한 미종결 `wms.receipts`를 모아 상태·유효 다음 액션을 요약(D4) |
| `wms_get_agent_decisions` | `p_tenant_id, p_warehouse_id, p_status default null, p_proposal_type default null` | `wms.agent_decisions`만(core schema) | 모든 테넌트/창고 멤버가 읽을 수 있는 조회 전용 함수(사람의 검토 화면 재료) — `LOGGED`/`PROPOSED`/`CONFIRMED`/`REJECTED` 전부 조회 가능 |

### 쓰기 RPC

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_log_agent_decision` | `p_tenant_id, p_warehouse_id, p_reasoning, p_actor_id, p_idempotency_key, p_proposal_type default 'DISPATCH_RETRY', p_target_entity_type default null, p_target_entity_id default null, p_signals_snapshot default null, p_correlation_id default null` | `PROCESS_AGENT`, `WMS_ADMIN` | `p_reasoning`이 빈 문자열이면 `INVALID:`. `wms.agent_decisions`에 `status='LOGGED'`로 생성, 이후 전이 없음 |
| `wms_propose_agent_action` | `p_tenant_id, p_warehouse_id, p_proposal_type, p_reasoning, p_proposed_action jsonb, p_actor_id, p_idempotency_key, p_target_entity_type default null, p_target_entity_id default null, p_signals_snapshot default null, p_correlation_id default null` | `PROCESS_AGENT`, `WMS_ADMIN` | `p_reasoning`, `p_proposed_action` 모두 필수. `status='PROPOSED'`로 생성 |
| `wms_confirm_agent_proposal` | `p_decision_id, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `WMS_ADMIN` | `PROCESS_AGENT` 호출 시 `FORBIDDEN:`(D6). `status`가 `PROPOSED`가 아니면 `INVALID:` |
| `wms_reject_agent_proposal` | `p_decision_id, p_reason, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `WMS_ADMIN` | `PROCESS_AGENT` 호출 시 `FORBIDDEN:`. `p_reason` 필수. `status`가 `PROPOSED`가 아니면 `INVALID:` |

모든 쓰기 RPC는 성공 시 `{result: 'ok', document_id, status, version,
next_actions, warnings?}` 형태를 반환하고, 각각 `wms.audit_events`에
`entity_type='agent_decision'` 레코드를 남긴다(다른 쓰기 RPC와 동일한 감사
관례 — `wms.agent_decisions` 자체가 이미 판단 이력을 담고 있어도, "이
테이블에 누가 언제 무엇을 썼는가"라는 표준 감사 사실은 별도로 계속
남긴다). 이때 `wms.agent_decisions.id`와 같은 값의 `correlation_id`를
쓰면, `wms_operations-audit-log`의 조인(D5)이 이 레코드도 자연어 요약에
포함시킬 수 있다.

## 역할 모델

새 역할을 추가하지 않는다. 기존 역할 재사용:

| 역할 | 이 계약에서의 권한 |
|---|---|
| `WMS_ADMIN` | 모든 RPC 호출 가능(읽기·판단 기록·제안 생성·승인·거부) |
| `WAREHOUSE_MANAGER` | 제안 승인·거부, 모든 읽기 RPC |
| `PROCESS_AGENT` | 모든 읽기 RPC(`wms_get_labor_balance_signals` 포함 — D2의 의도적 확장), 판단 기록(`wms_log_agent_decision`), 제안 생성(`wms_propose_agent_action`) — 승인/거부는 명시적으로 금지(D6) |
| (모든 멤버) | `wms_get_agent_decisions`, `wms_get_dispatch_delay_signals`, `wms_get_worker_next_actions` 읽기 |

`wms_get_labor_balance_signals`만 예외로 `PROCESS_AGENT`를 명시적으로
포함한다(D2) — 창고 전체 작업자 간 편차 비교가 이 신호의 본질이기 때문에
"본인 행만" 규칙(`wms_labor-management`의 D3)을 적용하면 무의미해지기
때문이다. 나머지 3개 읽기 RPC는 원래부터 모든 인증된 창고 스코프 멤버에게
열려 있다.

## RLS 패턴

기존 테이블과 동일하게, `wms.agent_decisions`:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer`
  RPC를 통해서만 이루어진다.

## MCP 도구 노출과 `PROCESS_AGENT` 허용 목록

`mcp/wms_mcp/mcp_server.py`에 8개 RPC(읽기 4 + 쓰기 4)를 감싸는 `@mcp.tool`을
추가한다. `docs/03-processgpt-integration.md`의 "에이전트 tool 허용 목록"에는
다음만 추가한다(tasks.md 후속 작업):

```text
wms.get_labor_balance_signals
wms.get_dispatch_delay_signals
wms.get_worker_next_actions
wms.get_agent_decisions
wms.log_agent_decision
wms.propose_agent_action

# 아래 2개는 허용 목록에 넣지 않는다 — PROCESS_AGENT가 호출하면 RLS/역할
# 검사에서 FORBIDDEN이 반환된다(D6, 안전망이 DB 레벨에도 있다)
# wms.confirm_agent_proposal
# wms.reject_agent_proposal
```

## 확장 지점

| 후속 영역 | 이 계약을 어떻게 확장하는가 |
|---|---|
| `wms_labor-management`(스펙 완료, DB 미구현) 구현 완료 | `wms_get_labor_balance_signals`가 실제로 값을 내기 시작한다 — 이 계약의 RPC 시그니처는 바뀌지 않는다. 향후 그 도메인이 실제 재배치 RPC를 정의하면, `proposal_type='LABOR_REBALANCE'` 제안이 승인된 뒤 사람 또는 ProcessGPT가 그 RPC를 다음 단계로 호출한다. |
| `wms_wes-material-flow-control`, `wms_wcs-bottleneck-routing` 구현 완료 | `wms_get_dispatch_delay_signals`가 실제로 값을 내기 시작한다 — 이 계약의 RPC 시그니처는 바뀌지 않는다. |
| `wms_operations-audit-log` 구현 완료 | 그 계약의 `wms_query_audit_log`/`wms_export_audit_log`가 `wms.agent_decisions`를 `correlation_id`로 조인해, 이 계약이 남긴 판단 근거를 사람+에이전트 통합 자연어 감사 로그에 포함시키기 시작한다(D5) — 이 계약의 스키마·RPC는 바뀌지 않는다. |

## 프론트엔드 확장 지점 (구현 아님, 위치만 기록)

- `/agent/proposals` — `status='PROPOSED'`인 `wms.agent_decisions`를 목록으로
  보여주고, `신호 스냅샷`·`판단 근거`를 함께 표시하며, 승인/거부 버튼을
  제공하는 화면 후보. `frontend/src/views/`에 `AgentProposalReviewView.vue`
  형태로 추가될 후보.
- `/agent/decisions` — `status='LOGGED'`인 자율 실행 판단 이력을 시간순으로
  보여주는 읽기 전용 화면 후보(감사용).

이번 변경은 이 화면들을 구현하지 않는다 — RPC/MCP 계약만 제공한다.

## Risks / Trade-offs

- **`wms_get_dispatch_delay_signals`, `wms_get_labor_balance_signals` 2개가
  선행 미구현 변경(`wms_wes-material-flow-control` + `wms_wcs-bottleneck-routing`,
  `wms_labor-management`)에 의존한다.** 완화책: 이 2개 RPC를 tasks.md에서
  별도 장으로 분리해, 나머지 6개 RPC(core schema만 의존)는 독립적으로
  구현·검증 가능함을 명시한다.
- **인력 불균형 신호가 `wms_labor-management`의 마이그레이션에 의존한다는
  것은, 그 계약이 지연되면 Labor Agent 매핑 전체가 값을 내지 못한다는
  뜻이다.** 완화책: 이 한계를 design.md와 spec.md 양쪽에 명시하고, RPC
  자체는 지금 설계해 두어 그 계약이 구현되는 즉시 값을 내기 시작하게
  한다(D2).
- **제안이 승인되어도 자동 실행되지 않는 것(D7)은 의도적 경계지만, 실제
  운영에서는 "승인 후 누가 실행 RPC를 호출하는가"라는 통합 공백을 남긴다.**
  완화책: `wms_wes-material-flow-control` design.md가 이미 같은 종류의
  공백(업무 오더 완료가 상위 엔티티로 자동 반영되지 않는 것)을 남긴 전례를
  따르며, 이 공백을 감추지 않고 tasks.md와 §5 카탈로그 갱신에 "미해결 통합
  지점"으로 명시한다.
- **`wms.agent_decisions`를 `wms.audit_events`와 분리한 것(D5)은 두 테이블을
  조인해야만 완전한 그림을 볼 수 있게 만든다.** 완화책: `correlation_id`
  컬럼을 양쪽에 유지하도록 tasks.md에 검증 항목을 두었고, 실제로
  `wms_operations-audit-log`가 그 조인의 소비자 쪽을 구현하기로 확정했다
  (D5) — 두 계약이 동시에 진행되며 서로의 최신 설계를 다시 확인해 수렴한
  결론이다.
- **"자율 실행 vs 제안"의 경계(D6)가 새로 생기는 모든 액션에 대해 사람의
  판단으로 그어진다 — 알고리즘으로 자동 도출되지 않는다.** 완화책: 이
  판단 근거(이미 다른 스펙에서 사람 전용으로 막힌 RPC는 계속 막는다, 실행
  RPC 자체가 없는 도메인은 항상 제안만 가능하다)를 D6 표에 명시적으로
  적어 다음 영역이 같은 패턴을 재사용할 수 있게 한다.
