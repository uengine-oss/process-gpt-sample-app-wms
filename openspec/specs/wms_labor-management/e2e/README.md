# `wms_labor-management` — 검증 기록

이 폴더는 인력 관리 계약(`openspec/changes/add-labor-management`)의 구현을 실제로
돌려 본 기록이다. 스크린샷은 전부 통과한 Playwright 실행에서 나온 실제
프레임이며, SQL 출력은 로컬 Supabase(`supabase_db_process-gpt-sample-app-wms`)에서
그대로 복사한 것이다.

## 구성

| 파일 | 내용 |
|---|---|
| `verify.sql` | 6개 RPC 전부와 spec.md의 모든 시나리오를 psql로 왕복 검증. 자체 픽스처(`LABOR-V-*`)를 만들고 지운다 — db reset 없이 반복 실행 가능 |
| `verify-run.txt` | 위 스크립트의 실제 출력 |
| `playwright-run.txt` | 전체 17개 테스트 실행 결과(이 영역 2개 + 기존 15개 회귀) |
| `screenshots/` | `frontend/playwright/e2e/labor-flow.spec.ts`가 남긴 8장. DOCX 매뉴얼의 재료 |

## 실행 방법

```bash
# 1) psql 검증 (자체 픽스처, 반복 실행 가능)
cd openspec/specs/wms_labor-management/e2e
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -f - < verify.sql

# 2) UI E2E (스크린샷 재생성 포함)
cd ../../../../frontend
npx playwright test labor-flow --reporter=list
```

## 무엇이 확인되었나

### 프라이버시 — 이 계약의 핵심

design.md D3은 같은 규칙을 두 겹으로 강제하라고 요구한다. 두 겹은 서로를
대신하지 못하므로, 각각을 **따로** 확인했다.

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| 작업자 A가 동료 B의 **개별 활동 행**을 테이블에서 직접 읽을 수 없다 | `verify.sql` H1 (세션 role을 `authenticated`로 내려 RLS만 남긴 상태) | B의 행 0건, 보이는 작업자 1명 |
| 같은 조회를 관리자가 하면 둘 다 보인다 | `verify.sql` H2 | 보이는 작업자 2명 |
| 작업자 A가 **집계 RPC**로도 B를 볼 수 없다 — B의 `actor_id`를 명시적으로 넘겨도 | `verify.sql` E2 | `scope=SELF`, 외부 행 0건, `p_actor_id`가 조용히 본인으로 대체됨 |
| 리더보드도 마찬가지 — 오류가 아니라 본인 행 하나 | `verify.sql` F3 | `row_count=1`, `rank=null`, `SELF_SCOPE_RANK_WITHHELD` |
| 화면에서도 같다 | `labor-flow.spec.ts` 테스트 1 | 동료의 `IN_PROGRESS` 행이 작업자 화면에 없고, 관리자 화면에는 있다 |
| 교차 테넌트 | `verify.sql` E5, H3 | RPC는 `FORBIDDEN`, 테이블 직접 조회는 0건 |
| 쓰기 권한 유출 없음 | `verify.sql` H4, H5 | `authenticated`에 `SELECT`만, INSERT/UPDATE/DELETE는 permission denied |

`SELF` 스코프에서 순위를 **숨기는** 선택(migration V3)은 의도적이다. 가짜 1위를
돌려주면 거짓말이고, 진짜 전체 순위를 돌려주면 "내 앞에 몇 명 있는지"가 새기
때문에 둘 다 하지 않고 `rank=null` + `SELF_SCOPE_RANK_WITHHELD`로 이유를 밝힌다.

### 대리 기록 차단 (D2)

| 시나리오 | 결과 |
|---|---|
| 작업자 A가 B의 `actor_id`로 활동 **시작** | `FORBIDDEN`, 행 생성 0건 (`verify.sql` B3) |
| 작업자 A가 B의 활동을 **완료** | `FORBIDDEN: ... belongs to another worker` (`verify.sql` C3) |
| `WMS_ADMIN`이 B 명의로 시작·완료 | 성공. `actor_id`는 B, `actor_role`은 **B의 역할** 스냅샷(관리자 역할이 아님) (`verify.sql` B4, C4) |
| 화면에 대리 기록 입력란이 있는가 | 없다. 관리자에게도 동료 행의 Complete/Cancel 버튼을 렌더링하지 않는다 (`labor-flow.spec.ts` 테스트 2) |

### 처리 시간 계산

`duration_seconds`는 `completed_at - started_at`의 **생성 컬럼**이라 호출자가
값을 보낼 수 없다(= 위조할 수 없다).

- spec.md의 예제(09:00:00 → 09:12:30, 48건)를 그대로 재현: `duration_seconds=750`
  (`verify.sql` C1, `labor-flow.spec.ts` 화면에 `12m 30s`).
- 취소된 1시간짜리 활동은 어떤 숫자에도 들어가지 않는다 — 완료 2건의 합계가
  `750+600=1350`초 그대로다(`verify.sql` D3).

> **검증 하네스 주의**: 시작·완료 RPC는 둘 다 서버의 `now()`를 쓰므로, 스크립트나
> UI에서 연달아 호출하면 처리 시간이 0초로 측정된다. `verify.sql`의
> `pg_temp.backdate()`와 Playwright의 `backdate()`는 `started_at`을 뒤로 밀어
> 알려진 값과 대조할 수 있게 하는 하네스 장치다 — 계약 동작이 아니다.

### 수요 추정 (단순 비율)

`actor_role`이 자유 텍스트라는 점을 이용해, 시드·픽스처 어디와도 겹치지 않는
합성 역할(`LABOR-V-ROLE`, 3건 / 90건 / 16200초 = 시간당 20건)로 spec.md의 예제를
정확히 재현했다(`verify.sql` G0~G1):

```
시간당 20건 x 8시간 = 1인 1교대 160건 -> ceil(480 / 160) = 3
```

- 올림 확인: 161→2, 160→1, 같은 물량에 근무시간을 절반으로 줄이면 3→6 (G2).
- 트레일링 창이 실제로 창이다: 1~3일 전 데이터를 `trailing_days=1`로 보면
  표본 0 → `INVALID` (G2b).
- 실제 시드 데이터에 대해서도 항등식
  `headcount == ceil(volume / (units_per_hour * shift_hours))`가 성립 (G2c).
- 표본이 없는 역할 → `INVALID: ... cannot estimate headcount`, 숫자를 만들어내지
  않는다 (G3).
- 일반 작업자 호출 → `FORBIDDEN` (G4), 화면에도 패널 자체가 렌더링되지 않는다.
- 응답의 `method`는 항상 `SIMPLE_RATIO`이고 `method_note`가 "머신러닝 예측이
  아니다"를 한국어로 명시한다 (G1b).

### 기존 계약과의 직교성 (D1)

이 마이그레이션은 `wms_register_arrival` / `wms_receive` /
`wms_record_quality_result` / `wms_apply_disposition` /
`wms_create_putaway_tasks`를 **한 줄도 고치지 않았다**. 회귀 방지로:

- `verify.sql` §J가 인력 활동을 하나도 걸지 않은 receipt으로 구매확정 → 입하 →
  입고 → 검사 → 적치 전체 체인을 걸어 보고, 그 receipt에 연결된 인력 활동이
  0건임을 확인한다.
- `labor-flow.spec.ts` 테스트 2가 세 개 쓰기 명령 중 `entity_type='receipt'`인
  감사 이벤트가 0건임을 확인한다.

### 감사 추적

세 쓰기 명령 모두 `wms.audit_events`에 `entity_type='labor_activity'`로 남고,
완료·취소는 `before`/`after` 쌍을 갖는다(`verify.sql` §I). 완료 이벤트의
`after.duration_seconds`가 실제 계산값(750)과 일치한다.

## 구현 중 발견한 것 / 설계 문서와 어긋난 곳

네 건 전부 마이그레이션 헤더(`V1`~`V4`)에 근거와 함께 기록했다.

1. **`design.md`의 RPC 파라미터 순서는 PostgreSQL에서 유효하지 않다.** 예를 들어
   `wms_start_labor_activity`는 `p_activity_label default null` 뒤에 기본값 없는
   `p_actor_id`, `p_idempotency_key`가 온다 — "기본값 있는 파라미터 뒤에 없는
   파라미터"는 문법 오류다. 필수 파라미터를 앞으로 끌어올렸다. 파라미터 집합·
   이름·타입·기본값은 설계 그대로이고, 이 저장소의 모든 호출자(supabase-js, MCP)가
   이름으로 넘기므로 관측 가능한 차이는 없다.

2. **`WAREHOUSE_MANAGER`도 본인 활동을 기록할 수 있게 했다.** design.md의 RPC 표는
   쓰기 역할을 네 개로 적었지만 D4 본문은 관리자가 "위 전체에 더해" 권한을
   갖는다고 쓴다. 현장에서 함께 일하는 관리자가 자기 작업을 기록하지 못하는 구멍이
   부자연스럽고, spec.md의 문장도 "이 네 역할이 할 수 있어야 한다"는 허용
   요구이지 "나머지는 금지"가 아니다. 교차 작업자 권한은 전혀 늘지 않는다 — D2의
   본인 검증이 그대로 걸리고, 대리 기록은 여전히 `WMS_ADMIN`만 가능하다.

3. **`SELF` 스코프의 리더보드 순위는 위조하지도 노출하지도 않고 보류한다** (위 참고).

4. **수요 추정의 처리량 단위는 `unit_count`다.** 트레일링 기간에 완료 활동은
   있는데 `unit_count`가 하나도 없으면, 조용히 "활동 건수/시간"으로 갈아타지 않고
   `INVALID`을 반환한다 — 표본 없음을 거부하라는 spec.md 요구와 같은 원칙이다.
   그래서 `complete_labor_activity`는 수량 없이 완료하면 `NO_UNIT_COUNT_RECORDED`
   경고를 돌려준다.

## 시드 데이터에서 밟은 함정 (기록해 둘 가치가 있는 것)

처음에 시드 인력 활동을 `date_trunc('day', now())` 기준 **D-1~D-3**에 심었더니
Playwright 테스트가 "완료 1건"을 기대한 자리에서 2건을 봤다. 원인은 타임존이다 —
시드는 DB의 UTC 자정을 기준으로 찍히고, 화면의 "오늘"은 **브라우저 로컬 타임존**의
자정을 기준으로 계산된다. UTC+9에서 "오늘"의 하한은 전날 15:00 UTC이므로, D-1
오후에 완료된 시드 행이 오늘 창 안으로 들어와 합계를 부풀렸다.

시드를 D-2~D-4로 물렸다(가장 넓은 로컬 하루 창(UTC+14)의 하한이 전날 10:00
UTC이므로 D-2면 안전하다). 트레일링 7일 수요 추정은 여전히 전부를 본다.
