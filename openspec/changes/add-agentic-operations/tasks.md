> **구현 완료 요약**: 8개 RPC 전부와 `wms.agent_decisions`를
> `supabase/migrations/20260805_agentic_operations.sql` 한 파일에 구현했다.
> **5장의 "선행 미구현 변경에 의존하는 읽기 RPC"라는 분리 조건은 해소됐다** —
> 이 문서가 작성된 뒤 `add-wes-material-flow-control`(20260728),
> `add-wcs-bottleneck-routing`(20260730), `add-labor-management`(20260803)가
> 모두 실제로 병합되었기 때문이다. 두 신호 RPC는 그 세 마이그레이션의 **실제**
> 테이블·뷰·함수를 읽고 설계 문서의 추정과 다른 부분을 맞춰 구현했으며, 차이
> 8건은 마이그레이션 헤더 V1~V8에 기록했다.
> 검증 기록: `openspec/specs/wms_agentic-operations/e2e/`,
> 매뉴얼: `openspec/specs/wms_agentic-operations/docs/`.

## 0. 선행 조건 확인

- [x] 0.1 `20260726_wms_core_schema.sql`이 대상 데이터베이스에 적용되어
      있는지 확인한다 — 이 변경의 8개 RPC 중 6개(`wms_log_agent_decision`,
      `wms_propose_agent_action`, `wms_confirm_agent_proposal`,
      `wms_reject_agent_proposal`, `wms_get_agent_decisions`,
      `wms_get_worker_next_actions`)와 `wms.agent_decisions` 테이블은 core
      schema만으로 착수 가능하다(design.md "정직한 전제 확인").
      → 적용되어 있다. 이 변경은 11번째 마이그레이션이다.
- [x] 0.2 `add-wes-material-flow-control`, `add-wcs-bottleneck-routing`의
      구현 여부를 확인만 하고, 1~4장(스키마·RLS·판단/제안 RPC·core-schema
      읽기 RPC) 착수 조건으로 삼지 않는다. `wms_get_dispatch_delay_signals`
      만 두 변경에 의존하므로 5장에서 별도로 다룬다.
      → **둘 다 구현되어 있다**: `20260728_wes_material_flow_control.sql`
      (`wms.dispatch_waves` 48행, `wms.work_orders` 63행),
      `20260730_wcs_bottleneck_routing.sql`(`wms.wcs_equipment_bottleneck_status`
      207행). 5장을 분리 착수할 이유가 사라져 같은 마이그레이션에 포함했다.
- [x] 0.3 `add-labor-management`의 구현 여부를 확인만 하고, 1~4장 착수
      조건으로 삼지 않는다. `wms_get_labor_balance_signals`만 그 변경에
      의존하므로 5장에서 함께 다룬다.
      → **구현되어 있다**: `20260803_labor_management.sql`
      (`wms.labor_activities` 108행, `wms_get_labor_productivity` 511행).
- [x] 0.4 `add-operations-audit-log`의 구현 여부를 확인한다 — 이 변경의
      스키마는 그 계약에 의존하지 않지만(design.md D5, `wms.audit_events`에
      컬럼을 추가하지 않기로 두 변경이 수렴했다), 그 계약의
      `wms_query_audit_log`/`wms_export_audit_log`가 이 변경의
      `wms.agent_decisions`를 `correlation_id`로 조인해 소비하므로, 이
      변경을 먼저 구현해 두면 그 계약의 통합(그 저장소의 2단계 구현)이
      더 일찍 완성된다는 점만 참고로 남긴다 — 이 변경 자체의 작업 순서에는
      영향이 없다.
      → **아직 미구현**(`supabase/migrations/`에 해당 파일 없음, 11개 영역 중
      마지막 영역). 이 변경이 먼저 착지했으므로 그 계약은 이제 조인 대상
      테이블을 실제로 갖고 시작한다. 조인이 성립하는 형태
      (`status`/`reasoning`/`correlation_id`)는 `verify.sql` §A가 회귀
      검증한다.

## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/`에 새 마이그레이션 파일(예:
      `<timestamp>_wms_agentic_operations.sql`)을 추가하고
      `wms.agent_decisions` 테이블을 design.md 데이터 모델대로 생성한다.
      "자율 실행 판단 근거 기록", "사람 승인이 필요한 제안 생성" Requirement
      검증. → `20260805_agentic_operations.sql`. design.md 표의 모든 컬럼을
      그대로 만들었고 인덱스 4종을 더했다.
- [x] 1.2 `proposal_type`, `status`에 `CHECK` 제약을 추가하고,
      `reasoning`이 빈 문자열이 아니어야 한다는 제약(또는 RPC 레벨 검증)을
      추가한다. `status='PROPOSED'`일 때만 `proposed_action`이 채워지도록
      RPC 레벨에서 강제한다.
      → `status`는 4값 CHECK, `proposal_type`은 **비어 있지 않음** CHECK만
      (design.md 데이터 모델이 "열린 집합"이라고 못박았으므로 값 목록을
      고정하면 후속 영역이 이 파일을 고쳐야 한다 — V7에 근거를 적었다).
      `reasoning`/`proposal_type` 공백 금지는 테이블 제약과 RPC 검증 양쪽에
      있고, `proposed_action`은 `(status='LOGGED') = (proposed_action is null)`
      제약으로 **테이블 레벨에서도** 강제된다(CONFIRMED/REJECTED는 제안에서
      내려온 상태이므로 조치를 계속 보유한다).
      `confirmed_by/at`, `rejected_by/at/reason` 짝 제약도 함께 추가했다.
      검증: `verify.sql` §A(제약 7종 출력), §B2, §C2.
- [x] 1.3 `status='PROPOSED'`인 레코드만 `wms_confirm_agent_proposal`/
      `wms_reject_agent_proposal`의 대상이 될 수 있도록 RPC 레벨에서
      검증한다(테이블 제약이 아니라 RPC 검증으로 처리 — 상태 전이 순서는
      애플리케이션 로직). → 공용 헬퍼 `wms._wms_load_agent_proposal`이
      존재·창고 스코프·역할·PROPOSED·버전을 이 순서로 검사한다.
      검증: `verify.sql` §B5(LOGGED 승인 시도), §D5(이중 승인).

## 2. RLS 정책

- [x] 2.1 `wms.agent_decisions`에 `enable row level security`를 적용하고,
      기존 테이블과 동일한 패턴(`warehouse_id in (select
      wms.current_warehouse_ids(tenant_id))`)의 `select` 정책만 추가한다.
      "테넌트·창고 단위 접근 통제" Requirement 검증.
      → 정책 1개(`agent_decisions_select`). `verify.sql` §K2가 정책 목록을
      출력해 회귀 방지한다.
- [x] 2.2 `authenticated`/`anon`에 `insert`/`update`/`delete` 권한을
      부여하지 않았는지 psql로 점검한다. → `verify.sql` §K1: `authenticated`에
      `SELECT` 하나, `anon`은 아무것도 없음. §K3은 세션 role을 실제로
      `authenticated`로 내려 세 가지 직접 쓰기가 전부
      `permission denied for table agent_decisions`임을 확인한다.
- [x] 2.3 교차 테넌트 접근 차단을 psql로 직접 검증한다(테넌트 A 사용자가
      테넌트 B의 판단·제안 이력을 조회·조작할 수 없음). "다른 테넌트의
      에이전트 판단 이력에는 접근할 수 없다" 시나리오 검증.
      → `verify.sql` §K3(테넌트 B 관리자에게 0건), §K4(RPC 조회·기록 모두
      `FORBIDDEN`), §K5(스코프 밖 승인 `FORBIDDEN`), §H6(다른 창고 신호).

## 3. 판단·제안 Command RPC (core schema만 의존)

- [x] 3.1 `wms.wms_log_agent_decision`을 구현한다 — 역할 검사
      (`PROCESS_AGENT`, `WMS_ADMIN`), `reasoning` 빈 문자열 거부,
      `wms.idempotency_records` 연동, `wms.audit_events` 기록. "자율 실행
      판단 근거 기록" Requirement의 3개 시나리오 검증.
      → `verify.sql` §B1(생성), §B2(빈/`null` 근거 모두 `INVALID`),
      §B3(`PROCUREMENT_BUYER` `FORBIDDEN`), §B4(`WMS_ADMIN` 허용).
- [x] 3.2 `wms.wms_propose_agent_action`을 구현한다 — 역할 검사,
      `proposed_action` 필수 검증. "사람 승인이 필요한 제안 생성"
      Requirement의 2개 시나리오 검증.
      → `verify.sql` §C1, §C2(`null`/`{}`/빈 근거 전부 `INVALID` — `{}`와
      `[]`도 "비어 있음"으로 본다), §C4(작업자 역할 `FORBIDDEN`).
- [x] 3.3 `wms.wms_confirm_agent_proposal`을 구현한다 — 역할 검사
      (`WAREHOUSE_MANAGER`, `WMS_ADMIN`만, `PROCESS_AGENT` 명시적 거부),
      `status='PROPOSED'` 검증, `expected_version` 검증, 다른 도메인 테이블을
      전혀 건드리지 않는지 확인. "에이전트 제안 승인" Requirement의 4개
      시나리오와 "제안 생성이 다른 도메인 테이블을 변경하지 않는다" 시나리오
      검증.
      → `verify.sql` §D2~§D5. 역할 거부가 **버전 검사보다 먼저** 오도록 순서를
      고정했다(에이전트가 잘못된 버전으로 찔러도 `CONFLICT`가 아니라
      `FORBIDDEN` — §D2). 다른 테이블 불변은 9개 테이블 행수+버전합 지문으로
      확인(§D1/§D4), 화면 쪽에서도 같은 지문을 비교한다
      (`agent-decisions-flow.spec.ts` 테스트 1).
- [x] 3.4 `wms.wms_reject_agent_proposal`을 구현한다 — 역할 검사, `reason`
      필수 검증, `expected_version` 검증. "에이전트 제안 거부" Requirement의
      3개 시나리오 검증. → `verify.sql` §E1~§E4. `reason` 검사는 역할·상태
      검사 **뒤에** 둔다("검토 권한이 없다"와 "이미 처리됐다"가 "사유를
      빠뜨렸다"보다 먼저 알려져야 한다).
- [x] 3.5 4개 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다. → 마이그레이션 말미. 내부 헬퍼
      `wms._wms_load_agent_proposal`은 의도적으로 grant하지 않는다
      (`wms._wms_load_labor_activity`와 동일).
- [x] 3.6 감사 이벤트 커버리지를 psql로 점검한다 — 4개 쓰기 RPC 각각 성공 시
      `wms.audit_events`에 올바른 `command`/`entity_type='agent_decision'`/
      `before`/`after`가 기록되는지 확인. "감사 추적" Requirement의 2개
      시나리오 검증. → `verify.sql` §L(4개 command 전부, 승인·반려는
      `before`/`after`에 `PROPOSED->CONFIRMED` / `PROPOSED->REJECTED` 전이
      포함). Playwright 테스트 1도 5건의 전이 문자열을 통째로 대조한다.
- [x] 3.7 멱등성 재시도 테스트: 동일 `idempotency_key`로
      `wms_propose_agent_action`을 2회 호출해 레코드가 1건만 생성되는지
      확인한다. → `verify.sql` §C3: 같은 `document_id` 반환, 행 1건.
- [x] 3.8 "이 계약은 PROCESS_AGENT의 기존 금지 목록을 넓히지 않는다"
      시나리오를 회귀 테스트로 재확인한다 — `wms_submit_purchase_approval`,
      `wms_apply_disposition`, `wms_resolve_equipment_fault`,
      `wms_exclude_equipment_from_routing`(구현되어 있다면)에 대해
      `PROCESS_AGENT`가 여전히 `FORBIDDEN:`을 받는지 psql로 확인한다.
      → `verify.sql` §J: 네 개 모두 + `wms_register_wcs_routing_policy`까지
      다섯 개가 `FORBIDDEN`. **각 RPC의 상태 가드가 통과하는 행을 골라서**
      호출한다 — 종결된 receipt에 `apply_disposition`을 걸면 상태 가드가 먼저
      터져 역할 가드를 확인하지 못하므로, §G7이 QC_COMPLETED 상태의 receipt을,
      §J 서두가 OPEN 상태의 장애를 따로 만든다. 같은 절에서 반대편(이미 허용된
      `wms_retry_work_order_dispatch`의 자율 실행 성공)도 확인한다.

## 4. core schema만 의존하는 읽기 RPC

- [x] 4.1 `wms.wms_get_worker_next_actions`를 구현한다 — 대상 작업자가
      관여한 미종결 `wms.receipts`를 상태별로 모아 유효 다음 액션을 반환.
      "작업자 다음 행동 안내 조회" Requirement의 3개 시나리오 검증.
      → `verify.sql` §G가 실제 core-schema RPC로 receipt을
      EXPECTED→ARRIVED→QC_PENDING→PUTAWAY_PENDING→PUTAWAY_COMPLETED까지
      몰고 가며 안내가 좁혀지는 것을 확인한다(§G2~§G5), 관여 없는 작업자는
      빈 결과(§G1/§G6), 실패 QC 분기의 `apply_disposition`도 확인(§G7).
      **편차 2건**: `wms.receipts`에 담당자 컬럼이 없어 관여를 감사 이벤트·
      품질 판정·폐기 판정·인력 활동 4곳의 합집합으로 유도하고
      `involvement_sources`로 그 경로를 노출했다(V5). spec.md 시나리오의
      `RECEIVING` 상태는 core schema에 존재하지 않으며(20260726이 `QC_PENDING`
      으로 접었다) 그 상태로 매핑했다(V6). `p_include_closed`(기본 false)를
      꼬리에 추가해 종결 항목도 볼 수 있게 했다 — 기본값이 spec.md 동작을
      보존한다.
- [x] 4.2 `wms.wms_get_agent_decisions`를 구현한다 — `status`,
      `proposal_type` 필터링 지원, `LOGGED`/`PROPOSED`/`CONFIRMED`/
      `REJECTED` 전부 조회 가능. "에이전트 판단·제안 이력 조회"
      Requirement의 2개 시나리오 검증.
      → `verify.sql` §F1~§F4. `status_counts`/`pending_review_count`는
      **필터와 무관하게 창고 전체**를 센다(제안 큐만 보면서도 뒤에 쌓인 이력
      규모를 알 수 있게). 알 수 없는 status는 조용히 0건이 아니라 `INVALID`.
- [x] 4.3 2개 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다.

## 5. 선행 미구현 변경에 의존하는 읽기 RPC (별도 착수 시점)

> **이 장의 전제가 해소됐다.** 아래 세 영역은 이 문서가 쓰인 뒤 모두 실제로
> 구현되었으므로(0.2/0.3 참고), 두 RPC를 나머지 6개와 같은 마이그레이션에
> 구현했다. 설계 문서가 "검토용 후보"로 적어 둔 스키마와 실제 스키마의 차이는
> 마이그레이션 헤더 V1~V4에 기록했다.

- [x] 5.1 `add-wes-material-flow-control`, `add-wcs-bottleneck-routing`의
      실제 구현 상태를 확인한다. 둘 다 구현되기 전까지는
      `wms.wms_get_dispatch_delay_signals`의 마이그레이션을 적용하지 않는다
      (design.md D3). → 둘 다 구현됨. 조건 충족.
- [x] 5.2 두 변경이 구현된 뒤, `wms.work_orders`(지연 임계 초과 `QUEUED`)와
      `wms.wcs_equipment_bottleneck_status`를 조인하는
      `wms.wms_get_dispatch_delay_signals`를 구현한다. "디스패치 지연 신호
      조회" Requirement의 3개 시나리오 검증.
      → `verify.sql` §I1~§I7. **편차 2건**: (V3) area 2에 지연 임계라는 개념이
      없어 `p_delay_threshold_minutes`(기본 15)를 꼬리에 추가했고, 대기 시간은
      `created_at`이 아니라 `updated_at`(마지막 시도 시각)부터 잰다 — 실패한
      재시도가 그 값을 갱신하므로 "또 재시도할 만한가"에 답하는 숫자가
      그쪽이다. (V4) 병목 뷰는 **설비 1행**이고 QUEUED 업무 오더에는 배정된
      설비가 없으므로 직접 조인이 불가능하다. 실제 선택 훅
      (`wms.wcs_select_available_equipment`)과 같은 술어로 후보 설비 집합을
      계산해 조인하고, 후보/IDLE/제외/병목/배차가능 개수와 병목 설비 목록을
      함께 반환한다. 지연 원인은 배열이며(겹칠 수 있다),
      `WAVE_NOT_RELEASED`를 추가해 "아직 차례가 아닌 것"과 "늦은 것"을
      구분한다 — 에이전트가 그것을 재시도로 고치려 들면 안 되기 때문이다.
- [x] 5.3 `add-labor-management`의 실제 구현 상태를 확인한다. 구현되기
      전까지는 `wms.wms_get_labor_balance_signals`의 마이그레이션을
      적용하지 않는다(design.md D2). → 구현됨. 조건 충족.
- [x] 5.4 `add-labor-management`가 구현된 뒤, `wms.wms_get_labor_productivity`
      를 창고 전체 스코프(비관리자 필터링 없이)로 호출·집계하는
      `wms.wms_get_labor_balance_signals`를 구현한다 — 평균 대비 편차 비율과
      `is_imbalanced` 계산, `PROCESS_AGENT`를 허용 역할에 명시적으로 포함
      (design.md D2). "인력 작업량 불균형 신호 조회" Requirement의 4개
      시나리오 검증.
      → `verify.sql` §H1~§H6. **편차 2건**: (V1) 그 함수를 **호출하지 않는다**.
      실제 구현(20260803 539~547행)이 비관리자 호출자를 `scope='SELF'`로
      강제 축소하므로 감싸면 `PROCESS_AGENT`가 자기 행 하나만 보게 되어 D2의
      역할 확장이 무의미해진다. 대신 area 8의 집계 **술어**를 그대로 재사용해
      (COMPLETED만, 같은 기간·테넌트·창고) 작업자 1행 단위로 다시 집계한다.
      (V2) spec.md가 값을 정하지 않은 임계값은 0.40 상수이며 응답에
      `imbalance_threshold`로 노출한다 — spec.md의 12-vs-2 예제가 평균 7,
      편차 ±0.7143으로 정확히 재현된다(§H1). 확장이 좁다는 것은 같은 세션에서
      `wms_get_labor_productivity`/`wms_get_labor_leaderboard`가 여전히
      `SELF`임을 나란히 출력해 확인한다(§H2/§H3, Playwright 테스트 2).
- [x] 5.5 두 의존 관계가 아직 구현되지 않은 환경에서 각 RPC를 호출(또는
      RPC 자체가 아직 마이그레이션되지 않았음)하면 빈 결과가 반환되거나
      명시적으로 "미구현" 상태로 문서화되는지 확인한다 — 오류를 내지
      않는다. → 선행 영역이 모두 구현된 지금은 **데이터가 없는** 경우로
      성격이 바뀌었고, 그때도 오류가 아니라 빈 결과 + 이유를 밝히는 note를
      반환한다: `NO_COMPLETED_LABOR_ACTIVITY_IN_PERIOD`,
      `SINGLE_WORKER_NO_COMPARISON`, `NO_QUEUED_WORK_ORDERS`,
      `ALL_QUEUED_WORK_ORDERS_WITHIN_THRESHOLD`, `NO_OPEN_ITEMS_FOR_ACTOR`.
      검증: `verify.sql` §H4, §I(초기 상태), §G1/§G6.
- [x] 5.6 2개 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다.

## 6. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 6.1 기존 `@mcp.tool` 패턴을 따라 아래 도구를 추가한다:
      `get_labor_balance_signals`, `get_dispatch_delay_signals`,
      `get_worker_next_actions`, `get_agent_decisions`,
      `log_agent_decision`, `propose_agent_action`,
      `confirm_agent_proposal`, `reject_agent_proposal`. 각 도구는 대응
      RPC가 실제로 마이그레이션된 이후에만 추가한다(3~5장 순서를 따름).
      → 8종 추가(총 74 → 82종). 기존 도구는 한 줄도 바꾸지 않았다.
- [x] 6.2 각 쓰기 도구 반환값에 `next_actions`를 채운다(예:
      `propose_agent_action` → `["confirm_agent_proposal",
      "reject_agent_proposal"]`). → RPC가 돌려주는 값을 그대로 전달한다
      (도구가 따로 지어내지 않는다). 읽기 도구에도 관찰 다음에 올 수 있는
      행동을 채웠다.
- [x] 6.3 `docs/03-processgpt-integration.md`의 "에이전트 tool 허용 목록"
      표에 이 변경의 도구 중 `PROCESS_AGENT`가 실제로 호출 가능한 6개
      (읽기 4 + `log_agent_decision` + `propose_agent_action`)만 추가한다.
      `confirm_agent_proposal`, `reject_agent_proposal`은 허용 목록에서
      제외한다는 note를 design.md 참조와 함께 남긴다(RLS/역할 검사가 이미
      DB 레벨에서 차단하므로, 허용 목록 누락은 이중 안전망).
      → 허용 목록에 6개 추가 + 제외 2개를 주석으로 명시. 아래에
      "note (에이전틱 운영)"을 추가해 세 에이전트 역할의 매핑, D7(승인≠실행),
      D2의 좁은 예외, `correlation_id` 조인을 설명했다.
      **design.md는 이 항목을 "이 변경이 직접 수정하지 않는 후속 작업"으로
      남겼지만, 동시 편집 충돌 대상이던 다른 영역이 전부 완료된 지금은
      충돌 위험이 없으므로 이 변경에서 직접 반영했다.**

## 7. E2E 검증 (`openspec/specs/wms_agentic-operations/e2e/`에 응집)

- [x] 7.1 제안 생성 → 승인 → 상태 확인, 제안 생성 → 거부 → 상태 확인 두
      왕복을 psql/Python으로 검증한다. → `verify.sql` §C~§E, 그리고 화면에서
      같은 두 왕복을 `agent-decisions-flow.spec.ts` 테스트 1이 수행한다.
- [x] 7.2 `PROCESS_AGENT`가 승인/거부를 시도하면 `FORBIDDEN:`이 반환되는지
      직접 호출로 확인한다. → `verify.sql` §D2, §E3, Playwright 테스트 2
      (실제 `PROCESS_AGENT` JWT 클레임으로 RPC 직접 호출).
- [x] 7.3 판단 기록·제안 생성이 `wms.agent_decisions` 외 다른 테이블을
      변경하지 않는지, 관련 도메인 테이블(예: `wms.receipts`,
      `wms.rfqs`)의 스냅샷을 전후로 비교해 확인한다.
      → `verify.sql` §D1/§D4가 9개 테이블(행수 + 버전 합계)의 지문을 승인
      전후로 비교한다. Playwright 테스트 1도 인력·업무오더·오버라이드·원장·
      receipt 지문을 클릭 전후로 비교하고, 반려 뒤에는 제안이 제외하자던
      설비에 `ACTIVE` 오버라이드가 0건임을 확인한다.
- [x] 7.4 작업자 다음 행동 안내를 실제 `wms.receipts` 상태 전이(EXPECTED →
      ARRIVED → RECEIVING)로 재현해 결과가 올바르게 좁혀지는지 확인한다.
      → `verify.sql` §G. spec.md의 `RECEIVING`은 core schema에 없는 상태이며
      `QC_PENDING`이 그 자리다(V6) — 전이 전체를 종결까지 몰고 갔다.
- [x] 7.5 (`add-labor-management` 구현 이후) 인력 작업량 불균형 신호를 실제
      `wms.labor_activities` 시드 데이터(작업자별 완료 건수를 의도적으로
      불균형하게 생성)로 재현해 `is_imbalanced` 판정과 `PROCESS_AGENT`의
      창고 전체 조회 권한을 확인한다 — 5장이 완료된 뒤에만 수행.
      → `verify.sql` §H(12 vs 2 시드, 평균 7, ±0.7143, 둘 다 불균형),
      화면에서도 `agent-decisions-flow.spec.ts` 테스트 1이 확인한다.
      시드는 **D-2에 앵커**한다 — UTC 자정 기준 시드가 브라우저 로컬 "오늘"
      창으로 새는 문제(area 8 시드 주석에 기록된 함정)를 피하기 위해서다.
- [x] 7.6 (선행 변경 구현 이후) 디스패치 지연 신호를
      `wms_wes-material-flow-control`의 실제 `QUEUED` 업무 오더로
      재현한다 — 5장이 완료된 뒤에만 수행.
      → `verify.sql` §I: 설비 없음 → IDLE 병목 설비 → 강제 제외 → 임계 이내
      → 미릴리스 웨이브 → 웨이브 필터까지 6단계. 화면에서도 임계값을 올리면
      0건, 되돌리면 1건으로 돌아오는 것을 확인한다.
- [x] 7.7 (`add-operations-audit-log` 구현 이후, 선택) 판단 기록이
      `correlation_id`로 그 계약의 `wms_query_audit_log` 결과에 조인되어
      자연어 요약에 나타나는지 확인한다 — 이 변경의 필수 완료 기준은
      아니며, 두 계약이 모두 구현된 환경에서만 수행하는 통합 확인이다.
      → 그 계약은 아직 미구현이므로 **소비자 쪽은 확인할 수 없다**. 이
      계약이 소유한 쪽은 확인했다: `verify.sql` §J가
      `wms.audit_events.correlation_id = wms.agent_decisions.correlation_id`
      로 실제 `LEFT JOIN`을 걸어 자율 실행 액션(`wms_retry_work_order_dispatch`)
      과 그 근거가 한 줄로 이어지는 것을 보이고, §L이 호출자가
      `correlation_id`를 넘기지 않은 경우의 폴백(감사 이벤트가 판단 id를
      쓴다, V8)을 확인한다. 남은 통합 확인은 e2e/README.md의 "남겨 둔 통합
      공백"에 명시했다.
- [x] 7.8 교차 테넌트/역할 오류 케이스(`FORBIDDEN`)와 버전 충돌 케이스
      (`CONFLICT`)를 psql로 직접 호출해 확인한다. → `verify.sql` §D3
      (`CONFLICT: expected version 7 but found 1`), §K3~§K5, §H5/§H6.
- [x] 7.9 실행 스크립트와 결과를
      `openspec/specs/wms_agentic-operations/e2e/` 아래에 정리한다.
      → `verify.sql`(자체 픽스처 `AGENT-V-*`, 반복 실행 가능),
      `verify-run.txt`(914줄, db reset 직후 실행), `playwright-run.txt`
      (21/21 통과 — 이 영역 2개 + 기존 19개 회귀), `screenshots/`(7장),
      `README.md`.

## 8. 문서/카탈로그 갱신

- [x] 8.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "에이전틱
      AI" 행에 "스펙 완료 → `wms_agentic-operations`" 비고를 추가한다(이미
      이 변경과 함께 완료됨 — 회귀 확인용 항목).
      → 이미 있던 문장에 **구현 완료** 절을 덧붙이고, "선행 3영역은 스펙만
      완료·DB 미구현"이라는 이제 사실이 아닌 문구를 실제 상태와 주요 편차
      (V1/V4/V5)로 교체했다.
- [ ] 8.2 이 변경이 archive될 때
      `openspec/specs/wms_agentic-operations/spec.md`로 동기화되는지
      확인한다(`openspec archive` 절차). — archive 시점의 작업으로 남긴다.

## 9. 프론트엔드

> **design.md가 "이번 변경 범위 아님"으로 미뤄 둔 항목이지만, 이 계약은
> 사람의 검토가 존재 이유이므로 사람이 설 자리가 없으면 계약이 반쪽이다.**
> 앞선 아홉 영역이 모두 화면까지 함께 냈고 E2E 회귀 스위트도 화면 기준이라,
> 이 변경에서 함께 구현했다.

- [x] 9.1 `frontend/src/router/index.ts`에 `/agent/decisions` 라우트와
      `AgentDecisionsView.vue`를 추가하고, `App.vue`의 WMS 내비게이션 그룹에
      "Agent Decisions"를 넣는다.
      → design.md는 `/agent/proposals`와 `/agent/decisions`를 두 화면 후보로
      적었지만 **한 화면으로 합쳤다**. 대기 제안과 처리된 이력, 그리고 그
      판단의 근거가 된 신호는 같은 질문("이 에이전트가 무엇을 왜 하고
      있는가")의 세 단면이고, 검토자가 화면을 오가며 맞춰 봐야 한다면 그
      자체가 검토를 형식화한다. 세 밴드로 나눴다 — 검토 대기 큐(근거를 접지
      않고 본문에 노출, 승인/반려 + 사유), 판단·제안 이력(상태·유형 필터,
      `LOGGED` 자율 실행 기록 포함), 에이전트가 보는 신호(인력 불균형 ·
      디스패치 지연 패널).
- [x] 9.2 승인/반려 버튼은 `WAREHOUSE_MANAGER`/`WMS_ADMIN`에게만 렌더링하고,
      인력 불균형 패널은 조회 권한이 없는 역할에게는 조회 자체를 시도하지
      않는다(정상 동작하는 화면 위에 `FORBIDDEN` 배너를 덮지 않기 위해).
      버튼을 감춘 것이 통제가 아니라는 점은 Playwright 테스트 2가 같은
      사용자로 RPC를 직접 호출해 확인한다.
- [x] 9.3 승인 알림 문구에 "승인은 상태 전이일 뿐이며 제안된 조치는 자동
      실행되지 않습니다"를 넣는다(D7) — 화면이 그 사실을 말하지 않으면
      관리자가 실행됐다고 오해한 채 떠난다.

## 10. 사용자 매뉴얼

- [x] 10.1 Playwright 스크린샷 7장을 재료로
      `openspec/specs/wms_agentic-operations/docs/`에 DOCX 운영자 매뉴얼을
      생성한다(`build_manual.mjs` →
      `agentic-operations-operator-manual.docx`, 1.6MB). 앞선 아홉 영역과
      같은 형식이며, "승인은 실행이 아닙니다"를 별도 강조 박스로 두 번
      반복한다 — 현장에서 가장 자주 오해할 지점이기 때문이다.
