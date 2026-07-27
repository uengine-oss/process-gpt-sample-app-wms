## Context

이 저장소의 `wms` 스키마(`supabase/migrations/20260726_wms_core_schema.sql`)는
구매→입고→검수→적치라는 문서 중심 업무만 모델링한다. 직접 확인한 결과, 이
마이그레이션 파일에는 `wms.warehouse_tasks` 같은 범용 작업 테이블이 없고,
"작업 배정·시작·완료"라는 개념도 없다. 유일하게 존재하는 것은:

- 각 쓰기 RPC(`wms_register_arrival`, `wms_receive`, `wms_record_quality_result`,
  `wms_apply_disposition`, `wms_create_putaway_tasks`)가 받는 `p_actor_id`
  파라미터 — 누가 호출했는지만 기록한다.
- `wms.audit_events` — `command`, `entity_type`, `entity_id`, `before`,
  `after`, `created_at` 컬럼만 가진 단일 이벤트 로그. "이 이벤트가 시작해서
  끝난 시간 구간"이라는 개념이 없다 — 한 시점의 스냅샷만 기록한다.

`docs/04-wms-wcs-market-feature-catalog.md` §2.1은 "인력 관리"를 "작업자별
생산성 측정, 필요 인력 수요 예측, 작업 가이던스, 게이미피케이션"으로
정리하고, Manhattan Active WM 절은 "Labor Agent(인력 불균형 감지·재배치)"와
"WMS·Labor Management·Slotting Optimization을 단일 터치 UI로 통합"을 실제
벤더 차별점으로 든다. 동시에 main repo
`openspec/changes/supabase-wms-erp-replacement/specs/wms_warehouse-task-execution/spec.md`는
훨씬 큰 목표 모델(`CREATED → READY → CLAIMED → IN_PROGRESS → COMPLETED` 생명주기,
skill 기반 배정, 원자적 claim, 오프라인 재전송, SLA 관찰)을 그리지만, 이
저장소는 그 모델을 구현하지 않았고 이 변경도 구현하지 않는다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블과 RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

이 영역은 area1~6(WCS/WES 체인)과 area7(야드/도크,
`wms_yard-dock-scheduling`)과 독립적이다. `wms.equipment`,
`wms.equipment_commands`, `wms.docks` 같은 개념을 참조하지 않으며, 그런 참조가
없는 것이 의도된 설계다 — 인력 관리는 "누가 얼마나 일했는가"를 다루는
WMS 운영 도메인 개념이지, 설비나 도크가 아니다.

## Goals / Non-Goals

**Goals:**

- 범용 작업(task) 모델을 새로 만들지 않고도 "작업자가 어떤 업무를 언제부터
  언제까지 처리했는가"를 기록할 수 있는 최소 단위의 인력 활동 로그
  (`wms.labor_activities`).
- 그 로그를 작업자별·역할별·일자별·활동 유형별로 집계하는 생산성 조회.
- 트레일링 N일 평균 처리량과 호출자가 제시한 예상 물량을 근거로 한 단순 비율
  계산 방식의 인력 수요 추정 — "머신러닝 기반 예측"이 아니라 "평균 처리량
  나눗셈"임을 명시한다.
- 기간별 생산성 리더보드 조회 — 포인트/배지 시스템 없이 "게이미피케이션"
  요구를 실용적으로 충족한다.
- 개인 생산성 데이터에 대한 프라이버시 규칙(본인 vs 관리자) — RLS와 RPC
  본문 양쪽에서 일관되게 강제한다.
- 기존 입고/검수/적치 RPC의 시그니처·동작을 전혀 바꾸지 않고 이 계약을
  얹을 수 있는 계측 메커니즘.
- 후속 확장(범용 작업 모델로의 진화, 실제 ML 수요 예측, 프론트엔드 대시보드)이
  이 계약을 다시 만들지 않고 얹을 수 있는 확장 지점.

**Non-Goals:**

- **범용 작업(task) 생명주기 모델.** main repo `wms_warehouse-task-execution`이
  그리는 `CREATED → READY → CLAIMED → IN_PROGRESS → COMPLETED` 상태 기계,
  skill 기반 배정, 원자적 claim 경쟁, 선행 작업 의존성(BLOCKED), 오프라인
  멱등 재전송은 이 변경의 범위가 아니다. `wms.labor_activities`는 "작업 큐"가
  아니라 "이미 일어난 업무 처리의 시간 구간 로그"일 뿐이다 — 배정도, 우선순위도,
  claim 경쟁도 다루지 않는다.
- **실제 머신러닝 기반 수요 예측.** Manhattan Active WM류 벤더가 실제로
  구현했을 법한 계절성·추세·이상치 보정 모델은 다루지 않는다. 이 계약이
  제공하는 것은 "트레일링 평균 처리량 ÷ 예상 물량"이라는 단순 비율 계산
  뿐이며, design.md와 spec.md 양쪽에서 이를 명시적으로 밝힌다.
- **포인트/배지/랭크 같은 게이미피케이션 시스템.** 리더보드 조회 RPC만
  제공한다 — 포인트 적립, 배지 부여, 레벨 시스템, 알림/축하 메시지 같은
  게임 메커니즘은 만들지 않는다.
- **Labor Agent류 자율 재배치.** 카탈로그의 "인력 불균형 감지·재배치
  Agent"는 이 계약이 만든 생산성 데이터를 ProcessGPT 에이전트가 향후
  소비할 수 있는 재료를 제공할 뿐, 이 변경 자체가 자율 재배치 로직이나
  에이전트를 구현하지 않는다.
- **작업 가이던스 신규 구현.** 카탈로그의 "작업 가이던스"는 기존 RPC들이
  이미 반환하는 `next_actions` 필드가 사실상 담당한다(`mcp/wms_mcp/mcp_server.py`
  기존 도구 참고) — 이 계약에서 별도 가이던스 계약을 새로 만들지 않는다.
- **이미 구현된 흐름에 대한 소급 계측.** D1에서 다루듯, 이 계약을 배포하기
  전에 이미 발생한 `wms_receive` 등 호출에는 대응하는 `wms.labor_activities`
  행이 생기지 않는다 — 생산성 집계는 이 계약 배포 이후 시점부터 누적된다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 인력 활동 계측은 (b) 감사 로그 타임스탬프 추론이 아니라 (a) 명시적
시작/완료 RPC 쌍으로 구현한다

**검토한 대안:**

- **(b) 추론형**: `wms.audit_events`의 기존 타임스탬프에서 시간을 역산한다
  (예: 같은 `receipt_id`에 대한 `wms_register_arrival`~`wms_receive` 사이
  간격을 한 작업자의 처리 시간으로 근사).
- **(a) 명시형**: 프론트엔드/MCP 도구가 업무 처리 전후로 새 RPC
  (`wms_start_labor_activity` / `wms_complete_labor_activity`)를 명시적으로
  호출해 시간 구간을 직접 기록한다.

**(b)를 기각한 이유:** 이 계약이 존재하는 이유 자체가 "생산성을 정확히
측정해 인력 수요 추정과 리더보드의 근거로 쓰는 것"이다. 그런데 (b)는
다음 문제를 안고 있고, 이 문제들은 바로 그 존재 이유를 훼손한다.

1. **행위자 모호성**: 같은 `receipt_id`를 여러 작업자가 나눠 만질 수 있다
   (한 사람이 `wms_register_arrival`을 호출하고 다른 사람이 `wms_receive`를
   호출하는 경우가 드물지 않다). 역산된 구간을 "한 사람의 처리 시간"으로
   귀속시키는 것 자체가 틀릴 수 있다.
2. **유휴 시간 오염**: 두 이벤트 사이 간격에는 실제 처리 시간뿐 아니라
   대기·휴식·다른 업무 처리 시간이 섞여 들어간다. 생산성 지표가 "실제 작업
   시간"이 아니라 "이벤트 간 벽시계 시간"이 되어 관리자가 보는 순간 왜곡된
   수치로 오판할 위험이 크다.
3. **커버리지 공백**: 입고 흐름 이후의 활동(예: 향후 출고/피킹이 추가될 때)마다
   "역산 가능한 이벤트 쌍"이 우연히 존재해야만 계측이 가능하다 — 새 업무
   유형이 추가될 때마다 "어느 이벤트 쌍을 근사식으로 쓸지"를 매번 새로
   설계해야 하는 임시방편이 반복된다.

**(a)를 채택한 이유:** 정확성이 이 계약의 핵심 가치이므로, 노이즈를 감수하는
근사보다 명시적 계측을 택한다. (a)의 통상적인 단점("기존 RPC를 수정해야
계측을 심을 수 있다")은 이 저장소 구조에서는 성립하지 않는다 — 기존 RPC
(`wms_receive` 등)의 SQL 시그니처를 전혀 건드리지 않고도, 그 RPC를 호출하는
**MCP 도구 래퍼**(`mcp/wms_mcp/mcp_server.py`)나 프론트엔드 호출 지점에서
`wms_start_labor_activity` → (기존 RPC 호출) → `wms_complete_labor_activity`
순서로 감싸기만 하면 된다. 즉 (a)는 "새 계측 계층을 기존 RPC와 나란히
추가"하는 것이지 "기존 RPC를 뜯어고치는 것"이 아니다 — `wms_register_dock`
등이 `wms_register_arrival`을 감싸지 않고 직교하게 공존한 야드/도크 계약의
D2 패턴과 동일한 결이다.

**받아들이는 트레이드오프:** 이 계약 배포 이전에 이미 실행된 흐름은 소급
계측되지 않는다(Non-Goals). 또한 호출자(프론트엔드/MCP 래퍼/에이전트)가
`wms_start_labor_activity`를 호출하지 않고 기존 RPC만 호출하면 그 업무는
계측되지 않는다 — 이는 강제되지 않는 계약이며, tasks.md에서 MCP 도구
래퍼 수준의 통합을 구현 작업으로 남긴다.

### D2. 시작/완료 RPC는 `p_actor_id`가 호출자 본인(`auth.uid()`)과 일치하는지
검증한다 — `WMS_ADMIN`만 예외로 대리 기록을 허용한다

기존 RPC(`wms_receive` 등)는 `p_actor_id`가 실제 호출자와 같은지 검증하지
않는다 — role 검사만으로 충분했다(감독자가 대신 기록하는 상황이 흔하고,
원장에 미치는 영향은 role만으로 통제 가능하기 때문). 그러나 이 계약은 다르다:
생산성 집계와 리더보드는 "숫자 자체가 목적"이므로, 다른 사람의 `actor_id`로
활동을 기록할 수 있으면 리더보드를 조작하거나 동료의 인사 평가에 쓰일 수
있는 지표를 왜곡할 수 있다. 그래서:

- `wms_start_labor_activity`, `wms_complete_labor_activity`,
  `wms_cancel_labor_activity`는 `p_actor_id <> auth.uid()`이면
  `FORBIDDEN:`을 반환한다.
- 예외로 `WMS_ADMIN`은 임의의 `p_actor_id`로 기록·정정할 수 있다(예: 오프라인
  작업자를 대신해 관리자가 사후 입력하는 데모 시나리오, 또는 잘못 기록된
  활동을 관리자가 취소하는 경우).

### D3. 개인별 생산성 프라이버시는 테이블 RLS와 RPC 본문 양쪽에서 이중으로
강제한다

`wms.labor_activities`에는 `warehouse_id` 스코프 정책 위에 "본인이거나
`WAREHOUSE_MANAGER`/`WMS_ADMIN`"이라는 행 단위 정책을 추가한다:

```text
using (
  warehouse_id in (select wms.current_warehouse_ids(tenant_id))
  and (actor_id = auth.uid() or wms.has_role(tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN'))
)
```

이 정책은 PostgREST/Supabase 클라이언트가 테이블을 **직접** 조회할 때
(`select * from wms.labor_activities`) 적용된다. 그러나 이 저장소의 기존
읽기 RPC(`wms_check_stock` 등)는 모두 `security definer`다 — SECURITY DEFINER
함수는 함수 소유자 권한으로 실행되므로, 함수 본문 안에서 명시적으로 권한을
검사하지 않으면 RLS를 우회해 버린다(실제로 `wms_check_stock`도 RLS에
기대지 않고 `if p_warehouse_id not in (select wms.current_warehouse_ids(...))`를
직접 검사한다 — 이 저장소의 기존 관례).

따라서 집계 RPC(`wms_get_labor_productivity`, `wms_get_labor_leaderboard`)도
같은 관례를 따라 함수 본문에서 명시적으로 분기한다:

- 호출자가 `WAREHOUSE_MANAGER`/`WMS_ADMIN`이면 창고 스코프 내 모든 작업자의
  집계를 반환한다.
- 그 외 역할이면 `actor_id = auth.uid()` 조건을 강제로 덧붙여 본인 행만
  반환한다(호출 파라미터로 다른 `actor_id`를 넘겨도 무시하고 본인 것으로
  덮어쓴다 — 조용히 필터링하지, `FORBIDDEN:`을 던지지 않는다. 리더보드
  성격상 "내 순위가 궁금해서 호출했는데 오류가 난다"는 경험이 부적절하기
  때문).

**중복(RLS + RPC 이중 검사)이 의도적인 이유:** 이 조회들이 향후 RPC를 거치지
않고 뷰/테이블을 직접 노출하는 방향으로 리팩터링되더라도(예:
`wms.labor_productivity_daily_v` 같은 집계 뷰를 클라이언트가 직접 조회하게
바뀌는 경우) 프라이버시 규칙이 RLS 한 겹만으로도 유지되도록 하기 위함이다.

### D4. 새 역할을 만들지 않고 기존 역할을 재사용한다

이 계약은 "작업자"라는 새 역할 카테고리를 만들지 않는다 — 이미 존재하는
업무 수행 역할(`INBOUND_OPERATOR`, `QUALITY_INSPECTOR`)이 곧 이 계약이
측정하는 "작업자"다. `wms.memberships.role`이 자유 텍스트이므로 마이그레이션
없이 재사용 가능하다:

- `INBOUND_OPERATOR`, `QUALITY_INSPECTOR`, `PROCESS_AGENT`: 본인의 활동
  시작·완료·취소, 본인 생산성 조회.
- `WAREHOUSE_MANAGER`, `WMS_ADMIN`: 위 전체에 더해 창고 스코프 내 모든
  작업자의 생산성 조회, 리더보드 조회, 인력 수요 추정 호출.
- `PROCESS_AGENT`가 자신의 명의로 활동을 기록하는 것도 허용한다 — 에이전트가
  대행한 업무도 "누가(무엇이) 얼마나 처리했는가"라는 이 계약의 질문에
  자연스럽게 포함되며, 집계 결과에서 `role='PROCESS_AGENT'`로 구분되므로
  사람과 에이전트의 처리량을 뒤섞지 않는다.

인력 수요 추정(`wms_forecast_labor_demand`)은 계획 성격의 판단이므로
`WAREHOUSE_MANAGER`, `WMS_ADMIN`만 호출할 수 있다 — 일반 작업자가 "내일 몇
명이 필요한가"를 조회할 수 있게 하지 않는다(관리 판단 정보이지, 작업자
개인이 필요로 하는 정보가 아니기 때문).

### D5. `activity_type`은 이 저장소가 실제로 가진 업무 시퀀스에 맞춘 제한된
값 집합으로 시작하고, `OTHER`로 확장 여지를 남긴다

이 저장소가 실제로 가진 "업무"는 입고 검수·품질 판정·처분(폐기/적치) RPC
시퀀스뿐이다. `activity_type`을 자유 텍스트로 두면 오탈자로 집계가 흩어질
위험이 있고, 완전한 enum으로 박으면 출고/피킹처럼 아직 이 저장소에 없는
업무가 추가될 때마다 마이그레이션이 필요하다. 절충으로 `CHECK` 제약에
현재 시퀀스에 대응하는 값(`RECEIVING`, `QUALITY_INSPECTION`, `PUTAWAY`,
`DISPOSITION`)과 향후 확장을 위한 탈출구(`OTHER`)를 함께 둔다. `OTHER`를
쓸 때는 `activity_label`(자유 텍스트, 사람이 읽는 설명)을 필수로 받아 최소한의
가독성을 보장한다.

## Data Model

### `wms.labor_activities` (신규 — 인력 활동 로그)

| 컬럼 | 설명 |
|---|---|
| `id` | PK |
| `tenant_id`, `warehouse_id` | 기존 관례와 동일한 스코프 FK |
| `actor_id` | 활동을 수행한 사용자(`auth.users`, D2로 본인 검증) |
| `actor_role` | 활동 시작 시점의 역할 스냅샷(`wms.memberships.role`에서 복사) — 이후 역할이 바뀌어도 과거 집계가 흔들리지 않도록 비정규화 |
| `activity_type` | `RECEIVING \| QUALITY_INSPECTION \| PUTAWAY \| DISPOSITION \| OTHER`(D5) |
| `activity_label` | `activity_type='OTHER'`일 때 필수인 자유 텍스트 설명 |
| `linked_entity_type`, `linked_entity_id` | 느슨한 참조(하드 FK 없음, area1 `wms.equipment_commands`·area7 `wms.dock_appointments`가 이미 쓰는 패턴) — 예: `('receipt', receipt_id)` |
| `unit_count` | 처리한 수량(선택, 호출자가 완료 시점에 제시) |
| `status` | `IN_PROGRESS \| COMPLETED \| CANCELLED` |
| `started_at` | 시작 시각(생성 시 `now()`) |
| `completed_at` | 완료/취소 시각(nullable, 완료·취소 시 채워짐) |
| `duration_seconds` | `completed_at - started_at`에서 계산되는 생성 컬럼(완료 상태에서만 값이 있음) |
| `version` | 낙관적 동시성 |
| `correlation_id`, `created_by`, `created_at`, `updated_at` | 기존 관례와 동일 |

제약: `check (activity_type <> 'OTHER' or activity_label is not null)`,
`check (status <> 'IN_PROGRESS' or completed_at is null)`,
`check (status = 'IN_PROGRESS' or completed_at is not null)`,
`check (unit_count is null or unit_count >= 0)`.

### 상태 기계

```text
labor_activities.status:
  IN_PROGRESS -> COMPLETED
  IN_PROGRESS -> CANCELLED
```

## RPC 계약 (기존과 동일한 envelope: `tenant_id, warehouse_id, actor_id,
idempotency_key, expected_version, correlation_id` 입력 / `{result,
document_id, status, version, next_actions, warnings}` 형태의 출력, 오류는
`CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 `RAISE EXCEPTION`)

| RPC | 파라미터(핵심) | 역할 | 설명 |
|---|---|---|---|
| `wms.wms_start_labor_activity` | `p_tenant_id, p_warehouse_id, p_activity_type, p_activity_label default null, p_linked_entity_type default null, p_linked_entity_id default null, p_actor_id, p_idempotency_key, p_correlation_id default null` | `INBOUND_OPERATOR`, `QUALITY_INSPECTOR`, `PROCESS_AGENT`, `WMS_ADMIN` | `p_actor_id = auth.uid()` 검증(D2, `WMS_ADMIN` 예외), `IN_PROGRESS`로 생성 |
| `wms.wms_complete_labor_activity` | `p_activity_id, p_unit_count default null, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | 시작과 동일 + `WMS_ADMIN` | `IN_PROGRESS` 전제조건, `completed_at=now()` 기록, `status='COMPLETED'` |
| `wms.wms_cancel_labor_activity` | `p_activity_id, p_reason default null, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | 시작과 동일 + `WMS_ADMIN` | `IN_PROGRESS` 전제조건, `status='CANCELLED'` |
| `wms.wms_get_labor_productivity` | `p_tenant_id, p_warehouse_id, p_period_start, p_period_end, p_actor_id default null, p_role default null` | 인증된 창고 스코프 사용자 전체(D3, 결과가 역할별로 필터링됨) | 작업자별·역할별·일자별·활동유형별 집계(완료 건수, 평균/합계 처리 시간, 합계 처리 수량) |
| `wms.wms_get_labor_leaderboard` | `p_tenant_id, p_warehouse_id, p_period_start, p_period_end, p_metric default 'completed_count'` | 인증된 창고 스코프 사용자 전체(D3, 비관리자는 본인 행만) | `p_metric`(`completed_count \| total_unit_count \| avg_duration_seconds`) 기준 작업자 순위 |
| `wms.wms_forecast_labor_demand` | `p_tenant_id, p_warehouse_id, p_role, p_expected_volume, p_trailing_days default 7, p_shift_hours default 8` | `WAREHOUSE_MANAGER`, `WMS_ADMIN`(D4) | 트레일링 `p_trailing_days`일의 역할별 평균 시간당 처리량으로 `recommended_headcount` 계산(단순 비율, ML 아님) |

`wms_forecast_labor_demand`는 표본이 없으면(트레일링 기간에 해당 역할의
완료된 활동이 없으면) `recommended_headcount`를 계산하지 않고 `INVALID:`
접두 오류를 반환한다 — 0으로 나누거나 근거 없는 숫자를 조용히 만들어내지
않는다.

## 확장 지점

- **프론트엔드**: `frontend/src/router/index.ts`에 `/labor/productivity`
  (본인/팀 생산성 대시보드), `/labor/leaderboard`(리더보드) 라우트를 추가하는
  것은 이 변경에 포함하지 않는다 — `wms_get_labor_productivity`,
  `wms_get_labor_leaderboard`를 소비하는 후속 작업으로 남긴다.
- **범용 작업 모델로의 진화**: 향후 이 저장소가 실제 `wms.warehouse_tasks`류
  범용 작업 큐(main repo `wms_warehouse-task-execution` 목표 모델)를
  구현하게 되면, `wms.labor_activities.linked_entity_type/id`를
  `('warehouse_task', task_id)`로 채우는 식으로 이 계약을 깨지 않고 연결할
  수 있다 — 이 변경이 시작/완료 RPC 쌍이라는 계측 계층을 먼저 만들어 두었기
  때문에, 범용 작업 모델이 나중에 추가되어도 생산성 집계 로직을 다시 만들
  필요가 없다.
- **Labor Agent류 자율 재배치**: `wms_get_labor_productivity`가 만드는 집계를
  ProcessGPT 에이전트가 주기적으로 조회해 "특정 역할·창고의 처리량이 임계치
  이하로 떨어졌다"를 판단하는 것은 이 계약을 깨지 않는 순수 소비자로 가능하다
  — 이 변경 자체는 그 판단 로직이나 자동 재배치 명령을 구현하지 않는다.
- **소급 계측**: D1의 트레이드오프로 남긴 "이 계약 배포 이전 데이터"는, 필요
  시 별도의 1회성 백필 스크립트(`wms.audit_events` 추론, 이 변경이 기각한
  방식 (b))로 근사치를 채울 수 있다는 가능성만 남겨 둔다 — 이번 변경의
  범위는 아니다.
