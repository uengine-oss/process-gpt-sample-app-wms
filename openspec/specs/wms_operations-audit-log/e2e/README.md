# `wms_operations-audit-log` — 검증 기록

이 폴더는 자연어 감사 로그 계약(`openspec/changes/add-operations-audit-log`)의
구현을 실제로 돌려 본 기록이다. 스크린샷은 전부 통과한 Playwright 실행에서
나온 실제 프레임이고, SQL 출력은 로컬 Supabase
(`supabase_db_process-gpt-sample-app-wms`)를 `supabase db reset`으로 초기화한
직후 그대로 복사한 것이다.

## 구성

| 파일 | 내용 |
|---|---|
| `verify.sql` | `describe_audit_event`와 2개 RPC 전부, spec.md의 모든 시나리오를 psql로 왕복 검증. 자체 픽스처(`AUDIT-V-*`)를 만들고 지운다 — db reset 없이 반복 실행 가능 |
| `verify-run.txt` | 위 스크립트의 실제 출력 |
| `playwright-run.txt` | 전체 23개 테스트 실행 결과(이 영역 2개 + 기존 21개 회귀) |
| `screenshots/` | `frontend/playwright/e2e/audit-log-flow.spec.ts`가 남긴 7장. DOCX 매뉴얼의 재료 |

## 실행 방법

```bash
# 1) psql 검증 (자체 픽스처, 반복 실행 가능)
cd openspec/specs/wms_operations-audit-log/e2e
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -f - < verify.sql

# 2) UI E2E (스크린샷 재생성 포함)
cd ../../../../frontend
npx playwright test audit-log --reporter=list
```

> `wms-flow.spec.ts`(area 1)는 SKU-A-001이 재주문점 아래에 있는 시드 상태를
> 전제로 하므로, **전체 스위트를 두 번 연속 돌리려면 사이에 `supabase db reset`이
> 필요하다.** 이 영역이 만든 제약이 아니라 원래부터 그랬다 — 위 기록은 reset
> 직후의 실행 결과다.

## 이 영역이 증명해야 하는 것

이 계약은 **테이블을 하나도 만들지 않는다.** 함수 3개가 전부다. 그래서 검증도
"새 기능이 동작하는가"보다 "기존 것을 망가뜨리지 않으면서 읽기만 하는가"에
무게가 실린다.

### 1. 요약이 페이지를 깨뜨리지 않는다

`wms.describe_audit_event`는 조회 시점에 계산되는 IMMUTABLE 함수다. 저장하지
않으므로 템플릿을 고쳐도 백필이 없고, LLM을 부르지 않으므로 같은 이벤트는
언제 읽어도 같은 문장이다(`verify.sql` §B8).

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| 실제로 쓰이는 command 전부에 전용 템플릿이 있는가 | `verify.sql` §B1 | **65/65**, 폴백으로 떨어진 것 0개, NULL·빈 문자열 0개 |
| 전용 템플릿이 없는 command 목록 | §B1b | 0행 |
| 알려지지 않은 명령 | §B2 | `future_entity 엔티티에 대해 wms_new_future_command 명령이 실행되었다.` |
| command와 entity_type이 **둘 다 NULL** | §B2 | `알 수 없는 엔티티에 대해 (이름 없는) 명령이 실행되었다.` — 오류도 NULL도 아니다 |
| `before`가 NULL(생성 이벤트의 전형) | §B3 | `구매 요청(RFQ)이 생성되었다 — 수량 120, 상태 TO_APPROVE.` |
| `after`가 `{}`라 필드가 전부 없음 | §B3 | `구매 요청(RFQ)이 생성되었다 — 수량 —, 상태 —.` |
| before→after 전이 | §B4 | `도크 DOCK-01의 상태가 변경되었다 — AVAILABLE → MAINTENANCE, 사유 정기 점검.` |
| 값 없는 선택 절이 찌꺼기를 남기는가 | §B5 | 남기지 않는다 — `, 사유 —`가 아니라 절 자체가 빠진다 |
| 한 command가 두 엔티티에 두 행을 남기는 경우 | §B6 | `wms_dock_vehicle`이 도크 행과 예약 행에 서로 다른 문장을 만든다 |

폴백은 **오늘 기준 dead code이고, 그게 의도다.** 65개 명령이 전부 전용 문장을
갖고 있으므로 실데이터에서는 절대 타지 않는다. 열두 번째 영역이 새 명령을
추가했을 때 요약이 NULL이 되거나 오류를 내지 않기 위해 존재한다 — design.md D1이
"새 명령을 추가할 때마다 이 함수를 갱신하는 것이 요구사항이 아니라 개선
기회가 된다"고 쓴 부분이다. §B2가 가공의 명령으로 그 분기를 직접 찌른다.

커버리지 수치는 마이그레이션 헤더가 인용하는 것과 같은 grep에서 나왔다:

```
$ grep -rhA3 'insert into wms.audit_events' supabase/migrations/ \
    | grep -oE "'wms_[a-z_]+'" | sort -u | wc -l
65
```

### 2. 역할 게이트는 진짜이고, 기존 열람 정책은 그대로다

이 계약의 가장 미묘한 부분은 **두 개의 서로 다른 접근 수준을 동시에 유지**하는
것이다. 원본 테이블 직접 SELECT는 예전처럼 모든 테넌트 구성원에게 열려 있고
(다른 화면들이 이미 그것에 의존한다), 요약·필터·내보내기가 붙은 이 표면만
좁혔다.

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| `INBOUND_OPERATOR` / `QUALITY_INSPECTOR` / `PROCUREMENT_BUYER` / `PROCESS_AGENT` × 조회 RPC | `verify.sql` §F1 | 4개 전부 `FORBIDDEN: role cannot read the operations audit log (WMS_ADMIN or AUDITOR required)` |
| 같은 4개 역할 × 내보내기 RPC | §F2 | 같은 `FORBIDDEN` |
| 테넌트 A 감사자가 테넌트 B를 조회 | §F3 | `FORBIDDEN` — `has_role`이 멤버십 스코프라 교차 테넌트 검사가 곧 역할 검사다 |
| 테넌트 B 관리자는 자기 테넌트를 읽고 A는 못 읽는다 | §F3 | `ok` / `FORBIDDEN` |
| **거절당한 그 사용자가 원본 테이블을 직접 SELECT** | §G | **성공** — 자기 테넌트 행이 보인다 |
| 같은 세션에서 다른 테넌트 행은 | §G | 0행 (기존 RLS 그대로) |
| `audit_events_select` 정책이 바뀌었는가 | §A | `tenant_id IN (SELECT wms.current_tenant_ids())` — 마이그레이션에 `alter policy`도 `drop policy`도 없다 |
| 화면·라우터·RPC 세 겹 | `audit-log-flow.spec.ts` 테스트 2 | buyer-a에게 nav 링크 없음 / URL 직접 입력 시 overview로 리다이렉트 / psql로 RPC 직접 호출해도 `FORBIDDEN` |

앞의 두 겹은 예의고, 실제 통제는 세 번째다. 테스트 2가 브라우저를 건너뛰고
같은 사용자로 RPC를 직접 부르는 이유가 그것이다.

`AUDITOR`는 새로 만든 역할이 아니다. `20260726_wms_core_schema.sql` 30행의 역할
주석에 처음부터 있었지만 어떤 RPC도 검사하지 않던 값이고, 이 계약이 그 첫
사용처다. 시드에 `auditor-a@demo.local`(`Demo1234!`)을 추가했고, 이 역할은
저장소 어디에도 쓰기 권한이 없다.

### 3. 페이지네이션 산수

120건 픽스처로 확인했다(`verify.sql` §E):

```
limit 50 / offset   0 → rows 50, total 120, page_count 3, has_more true
limit 50 / offset  50 → rows 50, 51~100번째 (received_qty 51 … 100)
limit 50 / offset 100 → rows 20, has_more false
limit 50 / offset 500 → rows  0, total 120  ← 여기가 요점
```

마지막 줄이 `count(*) over()`를 쓰지 않은 이유다. 윈도우 함수는 페이지를
넘어가면 행이 하나도 없어 총계 자체가 사라지고, 총계를 잃는 페이저는 없는
것만 못하다. 총계는 별도 `count(*)`로 센다.

범위 밖 인자는 조용히 clamp하지 않고 거절한다: `limit 0` / `limit 501` /
`offset -1` / `date_from > date_to` 전부 `INVALID:` (§E6, §E7).

### 4. 내보내기는 자기 자신을 감사하고, 잘라내지 않는다

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| 필터된 전체 집합이 페이지네이션 없이 온다 | §H1 | 120행 |
| 결과 안에 자기 자신이 들어 있는가 | §H2 | 없다 — `self_audit_event_id`는 반환된 rows에 없다 |
| 직후 재조회하면 보이는가 | §H3 | 보인다: `감사 로그 120건이 내보내졌다 — 기간 (처음) ~ (현재).` |
| 자기 감사 행의 actor | §H4 | 호출자(`auth.uid()`)이지 actor **필터**가 아니다 (V4) |
| 상한 초과 | §H5 | `INVALID: export matches 123 events, over the 3 row safety limit — narrow the date range or add a filter` |
| 거절된 호출이 자기 감사 행을 남기는가 | §H5 | 남기지 않는다 (before 3 → after 3) |
| 상한을 올릴 수 있는가 | §H6 | 없다 — `p_max_rows => 20000`은 `INVALID` (하드 실링 10000) |

`p_max_rows`를 파라미터로 만든 것이 V5다. 상한이 리터럴이면 그 분기를 테스트
하려면 10,001행 픽스처를 만들거나 tasks.md §3.4가 제안하듯 "상수를 잠깐 낮췄다
되돌리는" 수밖에 없는데, 후자는 **출시되는 코드가 아닌 코드를 검증하는 것**이다.
파라미터는 낮추기만 가능하고(하드 실링이 막는다) 출시되는 분기가 그대로 검증
대상이 된다.

### 5. 판단 근거 조인 (D3 2단계)

`add-agentic-operations`가 먼저 구현되어 있어서 1·2단계를 한 마이그레이션에
합쳤다(V2). 조인은 각 함수의 `left join lateral` 블록 하나에 갇혀 있고, 그
블록을 지우고 `ad.reasoning`을 `null::text`로 바꾸면 시그니처 변경 없이 1단계로
되돌아간다.

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| 같은 `correlation_id`의 근거가 요약에 반영된다 | §I2 | `설비 명령(MOVE)이 하달되었다 — 상태 DISPATCHED. (사유: AUDIT-V: … 대체 설비로 재배치했다.)` |
| 근거 원문도 별도 필드로 온다 | §I2 | `agent_reasoning`, `agent_decision_status`, `has_agent_reasoning` |
| **한 correlation_id에 판단 기록이 2건이면** | §I3 | 감사 이벤트는 여전히 1행 — `left join lateral … limit 1` (V3). 평범한 `LEFT JOIN`이었으면 행이 불어나 `total_count`와 어긋난다 |
| 근거가 없는 사람 명령 | §I4 | `has_reasoning=false`, 근거 문구 없는 정상 요약 3건 |
| 다른 테넌트가 같은 correlation_id를 쓴 경우 | §I5 | 섞이지 않는다 — 조인이 `d.tenant_id = e.tenant_id`로 스코프된다 |

UI 쪽에서는 에이전트가 **실제로 허용된 RPC**(`wms_create_rfq`)를 직접 호출하고
같은 `correlation_id`로 근거를 남긴 뒤, 감사자가 그 두 줄을 한 화면에서 읽는
것까지 확인한다(`audit-log-flow.spec.ts` 테스트 1, 스크린샷 04).

### 6. 화면이 보여주는 것은 이 화면이 만든 데이터가 아니다

이 계약의 스크린샷 1번은 감사 로그가 아니라 **Dock Schedule 화면**이다. 테스트가
그렇게 짜여 있기 때문이다:

```
admin-a  (UI)      → 도크 등록 + 정비 마감          두 건의 진짜 감사 이벤트
process-agent (RPC) → RFQ 생성 + 판단 근거 기록      같은 correlation_id
auditor-a (UI)     → 그것들을 한국어로 읽고, 걸러 보고, CSV로 내보낸다
buyer-a   (UI+RPC) → 세 개의 문 전부에서 막힌다
```

감사 로그가 자기가 만든 데이터를 보여 준다면 아무것도 증명하지 못한다. 그래서
30행짜리 페이지네이션 픽스처를 제외한 모든 행은 다른 영역의 RPC가 실제로 남긴
것이고, 검증도 "행이 있다"가 아니라 "문장이 무슨 일이 있었는지 말한다"를 본다 —
`도크 AUDIT-E2E-DOCK-01의 상태가 변경되었다 — AVAILABLE → CLOSED.`

CSV는 blob으로 실제 다운로드해서 열어 본다: 헤더 + 30행, 한국어 요약이 그대로
들어 있고, 내보내기 전후로 `wms_export_audit_log` 감사 이벤트가 정확히 1건
늘어난다.

## MCP

도구 2종(`query_audit_log`, `export_audit_log`)을 추가했고, **둘 다
`PROCESS_AGENT` 허용 목록에서 제외**했다(`docs/03-processgpt-integration.md`).
열한 개 영역 중 신규 도구가 전부 제외된 유일한 계약이다 — 감시 대상에게 감시
기록의 열람권을 주면 그 기록은 통제 수단이 아니게 된다. 두 도구는 이 파일에서
유일하게 세 번째 서비스 아이덴티티(`WMS_AUDITOR_EMAIL`)로 로그인하며,
PROCESS_AGENT 자격증명으로는 RPC가 `FORBIDDEN`을 돌려준다(§F1/§F2가 그것을 직접
확인한다).

## 알려진 성질 (버그 아님)

- **내보내기의 `p_correlation_id`는 필터이자 이번 호출의 상관관계 ID다**
  (design.md D4가 그렇게 정했다). 같은 필터로 두 번 내보내면 두 번째 결과에는
  첫 번째 내보내기의 자기 감사 행이 포함된다 — `verify.sql` §H3에서 121과 120
  두 줄이 나오는 이유이고, 내보내기도 감사 대상이라는 정의의 자연스러운 귀결이다.
- **`facets`는 필터와 무관하게 테넌트 전체를 스캔한다**(V6). 그래서 명령
  드롭다운의 모든 항목은 최소 1건을 갖는다 — E2E가 "결과 없음"을 확인할 때
  드롭다운이 아니라 자유 텍스트 필드를 쓰는 이유다.
- **핵심 3개 RPC(`wms_submit_purchase_approval` 등)는 `correlation_id`를 받지
  않는다.** 그 세 명령이 남긴 감사 이벤트는 `correlation_id`가 NULL이라 판단
  근거 조인 대상이 될 수 없다. 이 계약이 만든 제약이 아니라 area 1의 원래
  시그니처이고, `entity_id` 필터로 한 발주 건의 전체 이력을 잇는 것은 그대로
  된다(`verify.sql` §C1, §I4).
