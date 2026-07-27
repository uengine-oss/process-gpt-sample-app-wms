# `wms_agentic-operations` — 검증 기록

이 폴더는 에이전틱 운영 계약(`openspec/changes/add-agentic-operations`)의 구현을
실제로 돌려 본 기록이다. 스크린샷은 전부 통과한 Playwright 실행에서 나온 실제
프레임이며, SQL 출력은 로컬 Supabase(`supabase_db_process-gpt-sample-app-wms`)를
`supabase db reset`으로 초기화한 직후 그대로 복사한 것이다.

## 구성

| 파일 | 내용 |
|---|---|
| `verify.sql` | 8개 RPC 전부와 spec.md의 모든 시나리오를 psql로 왕복 검증. 자체 픽스처(`AGENT-V-*`)를 만들고 지운다 — db reset 없이 반복 실행 가능 |
| `verify-run.txt` | 위 스크립트의 실제 출력 |
| `playwright-run.txt` | 전체 21개 테스트 실행 결과(이 영역 2개 + 기존 19개 회귀) |
| `screenshots/` | `frontend/playwright/e2e/agent-decisions-flow.spec.ts`가 남긴 7장. DOCX 매뉴얼의 재료 |

## 실행 방법

```bash
# 1) psql 검증 (자체 픽스처, 반복 실행 가능)
cd openspec/specs/wms_agentic-operations/e2e
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -f - < verify.sql

# 2) UI E2E (스크린샷 재생성 포함)
cd ../../../../frontend
npx playwright test agent-decisions --reporter=list
```

> `wms-flow.spec.ts`(area 1)는 SKU-A-001이 재주문점 아래에 있는 시드 상태를
> 전제로 하므로, **전체 스위트를 두 번 연속 돌리려면 사이에 `supabase db reset`이
> 필요하다.** 이 영역이 새로 만든 제약이 아니라 원래부터 그랬다 — 위 기록은
> reset 직후의 실행 결과다.

## 이 영역이 증명해야 하는 것

이 계약은 스키마를 거의 늘리지 않는다(테이블 1개). 대신 **경계 하나**를 만든다.
그래서 검증도 기능 확인보다 경계 확인이 중심이다.

### 1. 액션 경계가 진짜로 DB에 있다

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| `PROCESS_AGENT`가 판단을 **기록**할 수 있다 | `verify.sql` B1 | `status='LOGGED'` 생성 |
| `PROCESS_AGENT`가 제안을 **생성**할 수 있다 | `verify.sql` C1 | `status='PROPOSED'` 생성 |
| `PROCESS_AGENT`가 **승인**하면 거부된다 | `verify.sql` D2, `agent-decisions-flow.spec.ts` 테스트 2 | `FORBIDDEN: PROCESS_AGENT may create proposals but not confirm or reject them` |
| `PROCESS_AGENT`가 **반려**해도 거부된다 | `verify.sql` E3, spec 테스트 2 | 같은 `FORBIDDEN` |
| 거부가 **상태 검사보다 먼저** 일어난다 | `verify.sql` D2 | 잘못된 `expected_version`으로 찔러도 `CONFLICT`가 아니라 `FORBIDDEN` — 에이전트가 버전을 탐지하는 통로가 없다 |
| 검토 권한 없는 사람 역할도 거부된다 | `verify.sql` E4, spec 테스트 2 | `FORBIDDEN: role cannot review agent proposals` |
| 화면에도 같은 경계가 있다 | spec 테스트 2 | `INBOUND_OPERATOR`에게 Confirm/Reject 버튼이 **렌더링되지 않는다** |

버튼을 감춘 것은 예의이고, 실제 통제는 RPC다 — spec 테스트 2는 화면에서 버튼이
없는 것을 확인한 **뒤에**, 같은 사용자로 RPC를 직접 호출해 `FORBIDDEN`을 받는
것까지 확인한다.

### 2. 아무것도 실행되지 않는다 (D7)

이 계약의 가장 흔한 오해는 "승인하면 그 조치가 실행된다"이다. 그런 디스패처는
일부러 만들지 않았고, 두 곳에서 그것을 증명한다.

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| 승인 전후로 다른 모든 WMS 테이블이 동일하다 | `verify.sql` D1/D4 (9개 테이블 행수 + 버전 합계 지문) | 지문 일치 |
| 화면에서 승인해도 같다 | spec 테스트 1 (인력·업무오더·원장·배정 지문) | 지문 일치 — 제안이 지목한 작업 이동이 **한 건도** 일어나지 않았다 |
| 반려해도 같다 | spec 테스트 1 | 제안이 제외하자던 AGV에 `ACTIVE` 라우팅 오버라이드 0건 |
| 응답이 그 사실을 말한다 | `verify.sql` D4, spec 테스트 1 | `CONFIRMED_BUT_NOT_EXECUTED` 경고, 화면 알림에 "자동 실행되지 않습니다" |

### 3. 기존 금지 목록이 넓어지지 않았다

`verify.sql` J는 `PROCESS_AGENT`로 이전 영역들의 사람 전용 RPC 5종을 직접
호출한다. 다섯 개 전부 `FORBIDDEN`이고, 각각 **역할 가드가 실제로 발동하는
상태의 행**을 대상으로 한다(예: `apply_disposition`은 QC_COMPLETED 상태의
receipt에 건다 — 종결된 receipt에 걸면 상태 가드가 먼저 터져 역할 가드를
확인하지 못한다. §G7이 그 행을 따로 만드는 이유다).

```
purchase_approval : FORBIDDEN: role cannot approve purchases
apply_disposition : FORBIDDEN: role cannot apply disposition
resolve_fault     : FORBIDDEN: role cannot resolve equipment faults
exclude_equipment : FORBIDDEN: role cannot exclude equipment from routing
routing_policy    : FORBIDDEN: role cannot manage wcs routing policies
```

반대편도 같은 절에서 확인한다 — 이미 허용된
`wms_retry_work_order_dispatch`는 `PROCESS_AGENT`가 **직접** 호출해 성공하고,
그 근거를 같은 `correlation_id`로 남기면 감사 로그에서 "무엇을 했는가"와 "왜
했는가"가 한 줄로 이어진다(D5가 `wms_operations-audit-log`에 약속한 조인).

## 신호 RPC를 실제 areas 2/4/8 스키마에 맞춘 결과

design.md는 이 두 RPC를 **선행 영역이 구현되기 전에** 그 영역의 design.md를 보고
설계했고, tasks.md §5는 그것들을 "착수하지 말 것"으로 분리해 두었다. 세 영역이
모두 실제로 구현된 지금, 실제 스키마를 읽고 맞췄다. 마이그레이션 헤더의 V 노트가
차이를 전부 기록하며, 요약하면:

| design.md의 가정 | 실제 | 처리 |
|---|---|---|
| `wms_get_labor_productivity`를 감싼다 | 그 함수는 비관리자 호출자를 `scope='SELF'`로 **강제 축소**한다(20260803 D3b) — 감싸면 에이전트가 자기 행 1개만 본다 | 감싸지 않고, 같은 집계 **술어**(COMPLETED만, 같은 기간·창고)를 창고 스코프로 다시 쓴다. V1 |
| 임계값 언급만 있고 값 없음 | — | 0.40 상수, 응답에 `imbalance_threshold`로 노출. spec.md의 12-vs-2 예제가 평균 7, 편차 ±0.7143으로 정확히 재현된다(`verify.sql` H1) V2 |
| `wms.work_orders`에 지연 임계 개념이 있다 | 없다 — QUEUED이거나 아니거나 | `p_delay_threshold_minutes`(기본 15)를 꼬리에 추가. design.md의 3인자 호출형은 그대로 컴파일된다. V3 |
| 업무 오더 ↔ 병목 뷰를 직접 조인 | 뷰는 **설비 1행**이고 QUEUED 업무 오더에는 배정된 설비가 아직 없다 | 실제 선택 훅(`wcs_select_available_equipment`)과 같은 술어로 **후보 집합**을 만들어 조인. 후보/IDLE/제외/병목/배차가능 개수를 전부 반환. V4 |
| 지연 원인이 둘 중 하나 | 겹칠 수 있다 | `delay_causes`를 배열로 반환. `WAVE_NOT_RELEASED`를 추가 — 아직 릴리스되지 않은 웨이브의 오더는 **지연이 아니라 차례가 아닌 것**이고, 에이전트가 재시도로 "고치려" 들면 안 된다. V4 |
| `wms.receipts`에서 `actor_id`로 담당자 식별 | 그 컬럼이 없다 | 감사 이벤트·품질 판정·폐기 판정·인력 활동 4곳의 합집합으로 유도하고, 어느 경로로 걸렸는지 `involvement_sources`로 노출. V5 |
| receipt 상태 `RECEIVING` | core schema에 없다(`QC_PENDING`으로 접혔다, 20260726 주석) | 열린 상태 5종 기준, `PUTAWAY_COMPLETED`만 종결. V6 |

실측 결과(`verify.sql` H, I):

```
mean 7.00 / threshold 0.40 → inbound-a 12건 +0.7143 ABOVE imbalanced
                             quality-a  2건 -0.7143 BELOW imbalanced

설비 없음        → ["NO_EQUIPMENT_REGISTERED"]
IDLE AGV + 장애1 → ["ALL_ROUTABLE_CANDIDATES_BOTTLENECKED"]
강제 제외 후     → ["ALL_CANDIDATES_EXCLUDED", "NO_IDLE_EQUIPMENT"]
미릴리스 웨이브  → [..., "WAVE_NOT_RELEASED"]
임계 이내        → 결과에서 제외 (임계를 0으로 낮추면 다시 들어온다)
```

## D2의 의도적 예외를 좁게 유지했는가

`wms_get_labor_balance_signals`만 `PROCESS_AGENT`에게 창고 전체를 연다. 그
예외가 다른 곳으로 새지 않았다는 것을 같은 세션에서 나란히 확인한다
(`verify.sql` H2/H3, spec 테스트 2):

| 같은 `PROCESS_AGENT` 호출자 | scope |
|---|---|
| `wms_get_labor_balance_signals` | **WAREHOUSE** (예외) |
| `wms_get_labor_productivity` | SELF (변화 없음) |
| `wms_get_labor_leaderboard` | SELF (변화 없음) |
| `wms.labor_activities` 직접 조회 | RLS 그대로 (변화 없음) |
| 재배치 실행 | 애초에 RPC가 없음 |

그리고 이 신호는 아무에게나 열려 있지도 않다 — `INBOUND_OPERATOR`가 호출하면
조용히 축소된 결과가 아니라 `FORBIDDEN`이다(`verify.sql` H5). 축소된 불균형
비교는 작은 답이 아니라 **틀린 답**이기 때문이다.

## RLS / 교차 테넌트 / 멱등성 / 감사

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| `authenticated`에 `SELECT`만 부여됐다 | `verify.sql` K1 | `SELECT` 하나 |
| 정책은 SELECT 1개뿐 | `verify.sql` K2 | `agent_decisions_select` |
| 세션 role을 `authenticated`로 내렸을 때 테넌트 A 7건 / 테넌트 B 0건 | `verify.sql` K3 | 격리됨 |
| 직접 INSERT/UPDATE/DELETE | `verify.sql` K3 | 셋 다 `permission denied for table agent_decisions` |
| 교차 테넌트 RPC 호출 | `verify.sql` K4 | 조회·기록 모두 `FORBIDDEN` |
| 창고 스코프 없는 관리자의 승인 | `verify.sql` K5 | `FORBIDDEN: no warehouse scope for agent decision ...` |
| 동일 `idempotency_key` 2회 제안 | `verify.sql` C3 | 같은 `document_id`, 행 1건 |
| 4개 쓰기 RPC 전부 감사 이벤트 | `verify.sql` L, spec 테스트 1 | `entity_type='agent_decision'`, 승인/반려는 `before`/`after`에 전이 포함 |
| `correlation_id` 폴백 | `verify.sql` L | 호출자가 안 넘긴 판단도 자기 id로 감사 로그에서 도달 가능(V8) |

> **K3 함정 기록**: 이 절을 처음 쓸 때 `set local role authenticated;`를 명시적
> 트랜잭션 없이 썼다. psql은 문장마다 자동 커밋하므로 `SET LOCAL`은 경고 하나만
> 남기고 **아무것도 하지 않는다**. 그 상태에서는 검사가 테이블 소유자로 돌아
> RLS를 통과해 버리고, 더 나쁘게는 음성 케이스인 `delete from
> wms.agent_decisions`가 **성공해서 픽스처를 전부 지웠다**(그 뒤 K5가 "unknown
> agent decision"으로 실패해서야 드러났다). 지금은 `begin; ... rollback;`으로
> 감싸고, 유효 role을 `current_user`로 함께 출력해 같은 실수가 조용히 지나가지
> 않게 한다.

## Playwright 시나리오 (2개, 총 21개 중)

에이전트가 하는 일은 **전부 화면 밖**에서 일어난다 — 이 앱에 에이전트 화면은
없고 앞으로도 없을 것이기 때문이다. `psql`을 `PROCESS_AGENT`의 JWT 클레임으로
실행해 ProcessGPT를 대신하고(따라서 RPC는 진짜 `PROCESS_AGENT` 호출자를 보고
역할 검사를 그대로 수행한다), 사람이 하는 일은 전부 브라우저에서 한다.

**테스트 1 — 관리자의 검토 왕복**
1. 에이전트가 off-UI로 판단 1건(LOGGED) + 제안 2건을 남긴다.
2. 관리자가 `/agent/decisions`를 열면 대기 2건, 각 카드에 **자연어 근거가
   접히지 않은 채** 보인다.
3. 같은 화면 아래 신호 패널이 에이전트가 본 것과 같은 값을 보여준다 —
   `scope=WAREHOUSE`, 불균형 2명, 지연 1건에 `ALL_ROUTABLE_CANDIDATES_BOTTLENECKED`.
   임계값을 120분으로 올리면 0건이 되고 15분으로 되돌리면 1건으로 돌아온다.
4. 인력 재배치 제안을 승인 → `CONFIRMED`, 승인자 이메일이 이력에 남고, 알림이
   "자동 실행되지 않습니다"라고 말하며, 9개 테이블 지문이 그대로다.
5. 라우팅 제안을 사유 없이 반려 → `INVALID: reason is required`. 사유를 넣고
   반려 → `REJECTED`, 사유가 이력에 보인다.
6. LOGGED 항목은 큐에 들어가지 않고 이력에만 있으며, 상태 필터가 3건을
   1/0/3으로 정확히 나눈다. 감사 이벤트 5건의 전이 문자열을 통째로 대조한다.

**테스트 2 — 에이전트는 자기 제안을 승인할 수 없다**
1. 에이전트가 새 제안을 만들고, 스스로 승인·반려를 시도해 둘 다 `FORBIDDEN`.
   제안은 `PROPOSED` 그대로다.
2. 같은 호출자로 `get_labor_balance_signals`는 `WAREHOUSE`,
   `get_labor_productivity`는 `SELF` — 예외가 한 RPC 폭이라는 것을 한 세션에서
   보여준다.
3. `INBOUND_OPERATOR`가 화면을 열면 근거·이력은 전부 읽히지만 버튼이 없고,
   인력 신호 패널 대신 이유를 적은 안내가 나온다. 그 뒤 같은 사용자로 RPC를
   직접 호출해 `FORBIDDEN: role cannot review agent proposals`를 확인한다.

`playwright-run.txt`가 21개 전체 통과 기록이다(이 영역 2개 + 기존 19개 회귀).

## 남겨 둔 통합 공백 (숨기지 않는다)

**승인된 제안을 누가 실행하는가.** `CONFIRMED`는 상태 플래그일 뿐이고 이
저장소에는 그 다음을 자동으로 잇는 것이 없다. 인력 재배치는 실행 RPC 자체가
없어서 사람이 수동으로 해야 하고, 설비 제외는 사람이 화면에서 직접
`wms_exclude_equipment_from_routing`을 호출해야 한다. 이것은 결함이 아니라
D7의 의도적 경계이지만, 운영에서는 "승인했는데 아무 일도 안 일어난다"로
경험되므로 제안 응답과 승인 응답 양쪽에 경고를 붙이고 화면 알림에도 적는다.

**`wms_operations-audit-log`와의 조인은 절반만 검증됐다.** 이 계약이 소유한
쪽(테이블 컬럼과 `correlation_id` 채우기)은 `verify.sql` A/J/L에서 확인했지만,
소비자 쪽(`wms_query_audit_log`가 실제로 조인해 자연어 요약에 근거를 넣는 것)은
그 계약이 아직 구현되지 않아 확인할 수 없다. tasks.md 7.7이 그 항목을 그
계약 구현 이후의 통합 확인으로 남겨 뒀다.
