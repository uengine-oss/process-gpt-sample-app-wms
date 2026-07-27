# `wms_slotting-optimization` — 검증 기록

이 폴더는 슬롯팅 최적화 계약(`openspec/changes/add-slotting-optimization`)의 구현을
실제로 돌려 본 기록이다. 스크린샷은 전부 통과한 Playwright 실행에서 나온 실제
프레임이며, SQL 출력은 로컬 Supabase(`supabase_db_process-gpt-sample-app-wms`)에서
`supabase db reset` 직후에 그대로 복사한 것이다.

## 구성

| 파일 | 내용 |
|---|---|
| `verify.sql` | 10개 RPC 전부와 spec.md의 모든 시나리오를 psql로 왕복 검증. 자체 픽스처(`SLOT-V-*`)를 만들고 지운다 — db reset 없이 반복 실행 가능 |
| `verify-run.txt` | 위 스크립트의 실제 출력 (786줄) |
| `playwright-run.txt` | 전체 19개 테스트 실행 결과(이 영역 2개 + 기존 17개 회귀) |
| `screenshots/` | `frontend/playwright/e2e/slotting-flow.spec.ts`가 남긴 9장. DOCX 매뉴얼의 재료 |

## 실행 방법

```bash
# 1) psql 검증 (자체 픽스처, 반복 실행 가능)
cd openspec/specs/wms_slotting-optimization/e2e
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -f - < verify.sql

# 2) UI E2E (스크린샷 재생성 포함)
cd ../../../../frontend
npx playwright test slotting-flow --reporter=list
```

---

## 먼저: 이 영역의 속도 신호는 오늘 존재하지 않는다 (그리고 그것을 숨기지 않았다)

design.md가 쓰일 때는 areas 5-8이 아직 미구현이었고, 거기서 예측한 명제는
"이 저장소의 어떤 RPC도 `AVAILABLE` 재고를 차감하지 않는다"였다. **그 예측을
설계 문서가 아니라 실제로 적용된 마이그레이션에 대고 다시 확인했다:**

```
$ grep -n 'stock_ledger_entries' supabase/migrations/*.sql | grep -v 20260726
supabase/migrations/20260727_wcs_equipment_control.sql:25:  (주석 한 줄, 그게 전부)
```

즉 `20260726_wms_core_schema.sql`이 **여전히** 이 저장소에서 원장에 쓰는 유일한
마이그레이션이다. area5의 `wms.outbound_orders`(20260731)는 실제로 구현되어
`status='COMPLETED'`까지 도달하지만 어떤 경로에서도 원장 행을 쓰지 않고(그
design.md Non-Goals가 스스로 약속한 대로), area6의 시뮬레이션은 투영 전용이라
원장을 건드리지 않는다. `verify.sql` §C1/§C2가 이 사실을 SQL로 직접 확인한다.

| 확인 | 어디서 | 결과 |
|---|---|---|
| 원장 전체에 `AVAILABLE` + 음수 `qty_delta` 행이 하나도 없다 | `verify.sql` C1 | `negative_available_rows = 0` |
| area5/6 계열 `source_type`으로 쓰인 원장 행이 하나도 없다 | `verify.sql` C2 | `0` |
| 그래서 속도 계산이 아무것도 못 찾고, **못 찾았다고 말한다** | `verify.sql` C3 | `NO_SIGNAL`, `included=0`, `skipped_no_data=7`, `NO_CONSUMPTION_SIGNAL_IN_WINDOW` |
| 가짜 스냅샷을 만들지 않았다 | `verify.sql` C4 | 스냅샷 0건 |
| 화면에서도 같다 | `slotting-flow.spec.ts` 테스트 1, 스크린샷 04 | 노란 경고 박스 "등급을 매기지 않았습니다", Generate 버튼 비활성 |

**따라서 ABC 산술을 실제로 돌려 보려면 신호를 직접 넣는 수밖에 없다.**
`verify.sql` §D와 `slotting-flow.spec.ts`의 `seedSyntheticConsumption()`은
superuser로 `wms.stock_ledger_entries`에 음수 `AVAILABLE` 행을 **직접
INSERT**한다. 이 행들은:

- 이 저장소의 어떤 RPC도 만들 수 없다(§C에서 방금 확인한 그대로),
- 미래의 출고 차감 RPC가 쓸 행 모양을 흉내 낸 **대역(stand-in) 데이터**이고,
- `source_type`이 `SLOT-V-synthetic-consumption` / `SLOT-E2E-synthetic-consumption`
  으로 표시돼 있어 즉시 식별·삭제 가능하며 두 스크립트 모두 끝에서 지운다.

그리고 두 스크립트 모두 **주입 전 상태를 먼저 검증한 다음** 주입한다 — 순서가
바뀌면 "원래 신호가 없다"는 사실이 관찰되지 않기 때문이다. 실제 출고 차감 RPC가
생기면 이 계약은 한 줄도 고치지 않고 진짜 신호를 내기 시작한다.

---

## ABC 분류 — 경계값을 정면으로 때렸다

주입 수량은 누적 비중이 **두 컷오프 위에 정확히** 떨어지도록 골랐다. 경계에서
어느 쪽으로 떨어지는지가 이 계산의 유일하게 애매할 수 있는 지점이기 때문이다.

| SKU | 소비량 | 이벤트 | 누적 비중 | 등급 |
|---|---|---|---|---|
| P1 | 60 | 3 | 60.00% | A |
| P4 | 20 | 2 | **80.00%** | A ← 정확히 80, 포함 |
| P2 | 15 | 1 | **95.00%** | B ← 정확히 95, 포함 |
| P3 | 5 | 1 | 100.00% | C |

`verify.sql` E2가 누적 비중을 함께 출력해 등급이 어디서 왔는지 눈으로 확인할 수
있게 했다. 비교는 나눗셈이 아니라 정수 곱(`cum_qty * 100 <= total_qty * 80`)으로
쓰여 있어(migration V5), 정확히 80%인 값이 부동소수점 오차로 경계를 놓치는 일이
구조적으로 불가능하다.

같은 §E에서 함께 확인한 것:

| 확인 | 결과 |
|---|---|
| 신호 있는 SKU만 스냅샷이 생긴다 — 나머지는 행 자체가 없다(등급 C가 아니다) | E3: 스냅샷 4건, 테넌트 제품 7종 |
| `candidate = included + skipped`가 항상 성립한다 | E1: 7 = 4 + 3 |
| `QC`/`SCRAP`의 음수, `AVAILABLE`의 양수는 신호가 아니다 | E4: 미끼 행 3개를 넣어도 합계 100 그대로 |
| 윈도우를 벗어나면 다시 "모름"으로 돌아간다 | E5: `included=0`, `skipped=7` |

---

## 추천 생성 — 빠진 것을 전부 세어서 돌려준다

`verify.sql` §F / 스크린샷 06. 들어가는 판 상태와 나오는 결과:

| SKU | 등급 | 상태 | 결과 |
|---|---|---|---|
| P1 | A | Z-20(rank 20)에 배정, A 정책 상한 5 | `RELOCATE_UNDERSERVED` → A-01(rank 1) |
| P4 | A | A-02(rank 2)에 배정 — 이미 상한 안 | 추천 없음, `skipped_already_optimal_count=1` |
| P2 | B | **B 등급 정책이 없음** | 추천 없음, `skipped_no_policy_classes=["B"]` |
| P3 | C | 배정 선언 자체가 없음 | `UNASSIGNED_HIGH_VELOCITY` → A-03(rank 3) |

세 가지 "안 한 이유"가 전부 **응답 필드로** 나온다는 것이 요점이다. 조용히
사라지는 SKU는 없다.

- **D2 (정책 없는 등급)**: 기본 상한을 발명하지 않는다. 위치가 5개인 창고와
  500개인 창고에서 "순위 5 이하"는 전혀 다른 뜻이라, 시스템 기본값은 위치가 적은
  창고에서 모든 위치를 A등급 자격으로 만들어 추천을 무의미하게 만든다.
- **D5 (배정 없는 SKU)**: `current_location_id=null`은 데이터 누락이 아니라
  "아무도 이 SKU를 어디 뒀는지 선언한 적이 없다"는 사실이다. 제외하면 가장 관리가
  안 된 SKU가 영영 추천되지 않는다.
- **V3 (대상 위치 선택)**: P3는 상한(40) 안에 드는 A-01(rank 1)이 아니라
  A-03(rank 3)을 받았다 — A-01은 이미 P1의 열린 추천이 노리고 있기 때문이다.
  한 배치가 같은 자리를 여러 SKU에 동시에 추천하지 않는다.
- **V4 (재실행)**: 같은 배치로 다시 생성하면 `generated=0`,
  `skipped_open_recommendation_count=2`. 정책을 고쳐 가며 반복 생성하는 것이
  설계된 워크플로(D3)라, 중복 PENDING이 쌓이면 안 된다(F4).

---

## HITL — 이 계약의 핵심 경계

`verify.sql` §G/§H, 스크린샷 07~09.

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| **추천을 만든 바로 그 에이전트가 그것을 승인할 수 없다** | `verify.sql` G1 | `PROCESS_AGENT` → review `FORBIDDEN`, apply `FORBIDDEN` |
| 화면에서도 같다 — 버튼 자체가 없다 | `slotting-flow.spec.ts` 테스트 2 | `조회 전용` 배지, Approve/Reject 버튼 0개 |
| `INBOUND_OPERATOR`는 **적용은 되고 결정은 안 된다** | `verify.sql` G2 / H2 | review `FORBIDDEN`, apply 성공 |
| 승인은 이동이 아니다 | `verify.sql` G3/G4, 스크린샷 08 | `ASSIGNMENT_UNCHANGED_UNTIL_APPLIED`, 배정은 여전히 Z-20 |
| 이미 검토된 추천은 다시 검토 못 한다 | `verify.sql` G5 | `INVALID (status=APPROVED)` |
| 미승인 추천은 적용 못 한다 | `verify.sql` H1 | `INVALID (status=REJECTED)`, 배정 변화 없음 |
| 적용하면 배정이 **실제로** 옮겨진다 | `verify.sql` H3, 스크린샷 09 | rank 20 → rank 1, `assigned_reason=SLOTTING_RECOMMENDATION`, `source_recommendation_id` 연결 |
| 배정이 없던 SKU는 **신규 생성**된다 (D5의 나머지 반쪽) | `verify.sql` H5 | `assignment_created=true`, `version=1` |
| 두 번 적용은 거부된다 | `verify.sql` H4 | `INVALID (status=APPLIED)` |
| 승인 후 대상 위치가 비활성화되면 적용이 거부된다 | `verify.sql` H6 | `INVALID: ... is INACTIVE`, 배정 그대로 |
| 버전 충돌 | `verify.sql` B6/B10/G3 | 위치·배정·추천 셋 다 `CONFLICT` |

`APPLIED`는 **기록이 바뀌었다**는 뜻이지 **물건이 옮겨졌다**는 뜻이 아니다.
그래서 적용 응답에는 언제나 `RECORD_ONLY_NO_PHYSICAL_MOVE_VERIFIED` 경고가
붙고, 화면 안내문에도 같은 말이 나온다. 배정 선언에는 마찬가지로 언제나
`DECLARATION_NOT_RECONCILED_WITH_PUTAWAY`가 붙는다 — 원장에 위치 축이 없어
`wms_create_putaway_tasks`와 대조할 방법이 아예 없기 때문이다.

---

## RLS / 권한 / 감사

| 확인한 것 | 어디서 | 결과 |
|---|---|---|
| 테넌트 A 멤버는 A의 위치·배정·정책·스냅샷·추천을 본다 | `verify.sql` K1 | 전부 non-zero |
| 테넌트 B 관리자는 **하나도** 못 본다 (뷰 포함) | `verify.sql` K2 | 6개 전부 0 |
| 뷰가 우회로가 아니다 | K2의 `overview_rows=0` | `security_invoker=true`(A5)라 기반 테이블 정책을 그대로 상속 |
| 교차 테넌트 RPC 호출 | `verify.sql` J1 | 등록/계산/검토 전부 `FORBIDDEN` |
| `authenticated`에 쓰기 권한이 없다 | `verify.sql` K3/K4 | INSERT/UPDATE/DELETE 전부 `permission denied`, 그랜트는 `SELECT`뿐 |
| 8개 쓰기 RPC + 2개 분석 RPC 전부 감사 이벤트를 남긴다 | `verify.sql` I1 | 10개 command 전부, `actor_id` 누락 0 |
| 적용은 추천과 배정 **양쪽**을 감사한다 | `verify.sql` I3 | 추천 `APPROVED→APPLIED`, 배정 `Z-20→A-01` |
| 멱등성 | `verify.sql` B5 | 같은 키 2회 호출 → 같은 `document_id`, 행 1건 |

배정의 이전 위치는 `wms.audit_events`의 `before`에만 남는다 — 별도 배정 이력
테이블은 설계상 만들지 않았고(D1), 그 감사 행이 곧 이력이다(I3가 그 행을
`location_code`로 풀어 보여 준다).

---

## 발견된 것 / 설계에서 벗어난 것

마이그레이션 헤더에 V1~V5로 전부 적어 두었다. 요약:

| # | 무엇 | 왜 |
|---|---|---|
| V1 | `wms_register_storage_location`의 `p_capacity_qty`를 `p_idempotency_key` 뒤로 옮김 | design.md 시그니처는 기본값 있는 파라미터 뒤에 기본값 없는 파라미터를 두어 PostgreSQL이 거부한다. 호출자는 전부 이름으로 넘기므로 순서는 관측되지 않는다(20260802/20260803도 같은 수정을 했다) |
| V2 | `skipped_no_data_count`의 모집단은 **테넌트의 제품 전체** | spec.md는 "창고에 등록된 제품"이라고 하지만 `wms.products`는 테넌트 스코프이고 제품-창고 레지스트리가 이 저장소에 없다. `candidate_product_count`를 응답에 함께 실어 산술을 검증 가능하게 했다 |
| V3 | 대상 위치를 임의로 고르지 않고 (미배정 → 미추천 → 최상 순위)로 정렬해 고름 | "상한을 만족하는 위치 중 하나"를 문자 그대로 하면 한 배치가 같은 자리를 여러 SKU에 추천한다. 필터가 아니라 선호라서, 전부 차 있어도 SKU를 조용히 버리지 않는다 |
| V4 | 열린(PENDING/APPROVED) 추천이 있는 SKU는 재생성에서 제외 | D3이 "정책 바꿔 가며 같은 배치로 재생성"을 워크플로로 규정하므로, 없으면 재실행마다 중복이 쌓인다 |
| V5 | ABC 경계는 포함(inclusive)이고 정수 산술로 비교 | spec.md의 시나리오가 정확히 80%/95%를 A/B로 요구한다. 나눗셈 대신 `cum*100 <= total*80`으로 써서 경계값이 오차로 미끄러지지 않게 했다 |

버그는 나오지 않았다. 다만 계약이 스스로 인정하는 한계 두 가지는 그대로 남아
있고, 응답 경고와 화면 안내문으로만 표현된다:

- **접근성 순위는 사람의 주관적 판단값이다.** 시스템이 창고 도면이나 실제 동선을
  계산해 검증하지 않는다 — 잘못 매긴 순위는 그대로 잘못된 추천이 된다.
- **배정 선언이 물리적 적치와 동기화되지 않는다.** 선언만 하고 실물을 옮기지
  않아도 이 계약은 그 어긋남을 감지하지 못한다(실사/순환재고 영역의 몫).

## 미착수로 남긴 것

- `wms.outbound_orders`(area5)의 `COMPLETED` 행을 속도 계산의 **보조** 신호로
  UNION하는 확장(tasks.md 8.1). 이번 변경은 그 테이블에 어떤 스키마 의존도
  만들지 않았다 — area5가 원장을 쓰기 시작하면 그때 자연스럽게 신호가 들어온다.
- ABC 컷오프(80/95)를 창고별 정책으로 여는 것, 건수 기준 분류(design.md 확장 지점).
