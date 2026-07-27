## Context

`docs/04-wms-wcs-market-feature-catalog.md`(§2.1 "재고 관리 및 최적화",
§4 Manhattan Active WM)가 정리한 슬롯팅 최적화는 "SKU 출하 빈도에 따라
고빈도 SKU를 접근성이 좋은 위치로, 저빈도 SKU를 접근성이 낮은 위치로
재배치해 피킹 동선을 줄이는" 기능이다. 이 기능이 성립하려면 최소한 두 가지
전제가 필요하다 — (1) "위치"라는 개념과 그 위치들 사이의 접근성 비교, (2)
"이 SKU가 얼마나 자주 나가는가"를 나타내는 신호. 이 저장소는 이 두 전제
모두를 가지고 있지 않다. 아래에서 두 전제 각각에 대해 무엇을 신설하고,
무엇을 신설하지 않는지, 그리고 왜 그렇게 정직하게 스코프를 그었는지를
다룬다.

## Option A/B 결정과 근거

proposal.md "Why"에서 이미 결론을 냈듯, 이 설계는 **Option A**(최소
위치/빈 모델을 이 스펙 자신의 기반으로 신설)를 채택한다.

Option B(위치를 `linked_entity_type`/`linked_entity_id` 같은 opaque
참조로 두고, 이 스펙은 속도 분석 + 추천 계층만 다루는 안)를 기각한 이유:

1. **테스트 불가능한 스펙이 된다.** `add-wcs-sequential-dispatch`
   design.md가 같은 갈림길에서 이미 지적했듯, Option B는 "재배치할 위치가
   이미 존재한다"고 가정하지만 그 위치를 만들거나 그 위치들 사이의
   접근성을 비교할 수단이 스펙 안에 없다. spec.md의 Given 절이 항상
   "어딘가에 이미 존재하는 위치 코드"를 전제해야 하는데, 그 전제를 만들
   수단이 스펙 밖에 있으면 E2E가 실제로 왕복 검증할 수 없는 참조가 된다.
   슬롯팅은 "위치 A가 위치 B보다 접근성이 낫다"는 비교가 핵심인데, 자유
   텍스트 위치 코드에는 비교 가능한 속성이 전혀 없다 — Option B로는
   "추천이 실제로 접근성을 개선하는가"를 검증하는 시나리오 자체를 쓸 수
   없다.
2. **위치 없이 "재배치"라는 단어 자체가 공허하다.** area5가 opaque 참조를
   써도 괜찮았던 이유는 그 스펙이 "이미 확정된 대상에 서열을 매기는" 것만
   다뤘기 때문이다(서열 값 자체가 이미 비교 가능한 정수). 슬롯팅은 그
   비교 기준(접근성)이 스펙 밖에 있으면 아무것도 비교할 수 없다.
3. **`wms_master-data`의 전체 위치 계층을 선점하지 않는다.** Option A를
   택했다고 해서 이 스펙이 창고 전체의 위치 마스터데이터 관리자가 되는
   것은 아니다. 아래 Non-Goals가 명시하듯, 이 스펙이 신설하는
   `wms.storage_locations`는 창고/구역/위치 코드와 접근성 순위, 선택적
   용량 수치만 가진 **평평한 레지스트리**다 — 통로·선반·빈 단위의 전체
   계층, 용량 관리 규칙 엔진, 위치-품목 적합성 규칙(위험물/온도대)은 전부
   범위 밖에 남긴다. `wms_master-data`가 언젠가 이 영역을 정식으로
   흡수한다면, 이 스펙의 최소 테이블은 그 상위 스키마로 대체될 후보로
   design.md에 명시해 둔다(아래 "확장 지점").

## 정직한 전제 확인 (구현 상태와 속도 신호의 성격)

### 위치/빈 모델이 아예 없다

`supabase/migrations/20260726_wms_core_schema.sql`을 직접 읽고 확인한
사실:

- `locations`/`bins` 테이블이 전혀 없다.
- `wms.stock_ledger_entries`는 `(tenant_id, warehouse_id, product_id,
  status)` 단위로만 재고를 기록한다 — 창고 내 어느 위치인지 나타내는
  컬럼이 없다.
- `wms.inventory_availability_v`도 같은 4개 축(+ 상태별 합계)만 투영한다.

이 스펙이 신설하는 `wms.sku_location_assignments`(아래)는 **원장에서
유도되는 값이 아니다.** 원장에 위치 축이 없으므로, "이 SKU가 지금 어느
위치에 있는가"는 원장을 조회해서 계산할 수 없다 — 운영자가 별도로
선언·갱신하는 독립 배정 레코드로만 존재한다. 이 스펙은 이 선언 배정을
실제 물리적 적치 실행(`wms_create_putaway_tasks`)과 자동 동기화하지
않는다 — 적치 RPC는 위치를 전혀 다루지 않기 때문이다(위 확인 사항).
자동 동기화를 만들려면 `wms_create_putaway_tasks`의 계약 자체를 바꿔야
하는데, 이는 area1(입고 슬라이스)의 기존 스펙 문구를 건드리는 일이므로
이번 변경의 범위 밖이다.

### 소비/출고로 인한 재고 차감 이력이 오늘 시점에는 존재하지 않는다

`wms_receive`, `wms._wms_finalize_disposition`, `wms_apply_disposition`,
`wms_create_putaway_tasks`를 전부 직접 읽고 확인한 사실 — 이 저장소에
현재 구현된 RPC가 `wms.stock_ledger_entries`에 기록하는 `qty_delta`는
**예외 없이 전부 양수**다:

| RPC | 기록 | 부호 |
|---|---|---|
| `wms_receive` | `status='QC'` | `+p_qty` |
| `_wms_finalize_disposition`(SCRAP 또는 AVAILABLE 처분 시 공통 호출) | `status='QC'` | `-received_qty`(같은 트랜잭션 안에서 QC 잔액을 상쇄) |
| `_wms_finalize_disposition`(위와 동일 호출의 두 번째 insert) | `status='SCRAP'` 또는 `'AVAILABLE'` | `+received_qty` |

즉 `AVAILABLE` 상태 재고를 소비 방향(음수)으로 차감하는 경로가 이
저장소에 **전혀 없다** — 이 마이그레이션이 적용된 이후 지금까지 어떤
호출도 `AVAILABLE` 잔량을 줄인 적이 없다. `add-wcs-sequential-dispatch`
(area5)가 정의한 `wms.outbound_orders`도 그 design.md Non-Goals에서
스스로 "포장·출하 확정과 원장 차감... `wms.stock_ledger_entries`를
갱신하지 않는다"고 명시한다 — 즉 area5가 이 저장소에 실제로 적용되어도
소비 이력 공백은 메워지지 않는다.

**따라서 이 스펙의 속도(velocity) 신호는 "오늘 계산하면 항상 비어
있다."** 이는 버그가 아니라 이 저장소의 현재 스코프가 만든 사실이다. 이
설계는 이 사실을 우회하지 않는다 — 가짜 신호(예: 입고 빈도를 출고
빈도인 것처럼 재사용, 또는 데이터가 없는 SKU에 임의 기본 등급 부여)를
만들지 않고, 대신:

- 속도 계산 RPC(`wms_compute_sku_velocity`)는 관찰 윈도우 안에서
  `status='AVAILABLE' and qty_delta < 0`인 원장 행만 신호로 삼는다 —
  **미래에 소비/출고 RPC가 이 조건을 만족하는 행을 기록하기 시작하는
  순간부터 이 계약은 아무것도 바꾸지 않고도 실제 신호를 만들어낸다**
  (전진 설계, forward-looking).
- 그런 이력이 전혀 없는 SKU는 등급 없이 분류 대상에서 **명시적으로
  제외**되고, RPC 응답의 `skipped_no_data_count`에 그 사실이 드러난다.
  요청 코드가 이 값을 확인하지 않고 결과를 "정상적으로 계산된 낮은
  우선순위 SKU들"이라고 오해하지 않도록, spec.md의 Scenario가 이 동작을
  직접 검증한다(아래 Requirement: SKU 출하 속도 계산).

### area5 `wms.outbound_orders`를 보조 신호로 삼지 않는 이유

area5(`add-wcs-sequential-dispatch`)의 `wms.outbound_orders`는
`status='COMPLETED'`인 행이 "이 SKU가 이 시점에 출고 이행 파이프라인을
통과했다"는 사실을 담고 있어, 원장 차감이 없어도 출고 빈도의 근사 신호로
쓸 수 있어 보인다. 그럼에도 이 스펙의 마이그레이션은 그 테이블을 읽지
않는다:

1. area5도 아직 이 데이터베이스에 적용되지 않은 미구현 변경이다 — 이
   스펙의 스키마가 area5의 스키마 존재를 전제하면, area5가 적용되지 않은
   환경에서는 이 마이그레이션 자체가 실패한다.
2. 이번 작업의 명시적 원칙("areas 1-8과 독립적으로 스펙화한다, 불필요한
   의존을 강제하지 않는다")과, area4(`wms_wcs-bottleneck-routing`)가
   보여준 선례 — DB 스키마 의존은 최소화하고 통합은 "구현 통합 의존성"
   메모로만 남긴다 — 를 따른다.

대신 아래 "확장 지점"에 "area5가 적용된 환경에서는
`wms.outbound_orders.status='COMPLETED'` 행을 `wms_compute_sku_velocity`의
**추가** 신호 소스로 UNION할 수 있다"는 후속 확장 후보만 문서로 남긴다 —
이번 변경의 어떤 테이블/함수도 이 확장을 전제로 만들지 않는다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블/RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

## Goals / Non-Goals

**Goals:**

- 창고 안에 보관 위치를 등록·관리하는 최소 레지스트리 — 구역 코드, 위치
  코드, 접근성 순위(정수, 낮을수록 접근성 좋음), 선택적 용량 수치.
- SKU가 현재 어느 위치에 배정되어 있다고 운영자가 선언한 값을 저장·갱신
  하는 계약(원장에서 유도하지 않음 — 위 "정직한 전제 확인" 참고).
- 창고별로 속도 등급(A/B/C)마다 "이 등급의 SKU는 접근성 순위 몇 이하
  위치에 있어야 하는가"를 운영자가 정의하는 정책.
- `wms.stock_ledger_entries`의 `AVAILABLE` 상태 음수 `qty_delta`만을
  신호로 삼아 SKU별 출하 속도(수량·건수)를 관찰 윈도우 단위로 계산하고
  ABC 등급을 매기는 계약 — 신호가 없는 SKU는 등급 없이 명시적으로 제외.
- 속도 스냅샷과 현재 위치 배정, 등급별 정책을 비교해 "이 SKU를 이 위치로
  옮기는 것을 추천한다"는 재배치 추천을 생성하는 계약(추천 생성 자체는
  자동화 가능 — 물리적 이동 결정이 아니라 분석 결과이므로).
- 추천을 사람이 검토(승인/반려)하고, **승인된 추천만** 실제 SKU-위치
  배정을 바꾸는 HITL 적용 계약 — 자동 적용은 없다.
- 완성된 재배치 추천 현황(등급, 현재 위치, 추천 위치, 상태)을 조회할 수
  있는 통합 뷰.
- 후속 확장(area5 보조 신호 통합, `wms_master-data`로의 위치 모델 승격)이
  이 계약을 다시 만들지 않고 그 위에 얹을 수 있는 확장 지점.

**Non-Goals:**

- **위치 계층 전체(통로·선반·빈 단위), 위치 용량 관리 규칙 엔진, 위치-품목
  적합성 규칙(위험물/온도대/중량 상한).** `wms.storage_locations`는
  평평한 레지스트리이지 계층이 아니다 — `wms_master-data`의 미래 확장
  후보로만 남긴다.
- **실제 이동 경로/동선 시뮬레이션, 피킹 시간 예측 모델.** 이 계약은
  "접근성 순위"라는 운영자가 직접 매긴 정수 하나만 다룬다 — 그 순위를
  계산하는 알고리즘(예: 실제 창고 도면 기반 거리 계산)은 다루지 않는다.
- **재배치 추천을 자동으로 적용(사람 승인 없이).** "보조적, 자율적이지
  않음" 원칙 — `wms_replenishment-planning`의 RFQ 승인 패턴과 동일.
- **속도 계산에 입고 이력, 처분 이력, 또는 다른 상태(`QC`, `RECEIVING`,
  `SCRAP`)의 `qty_delta`를 신호로 사용.** 오직 `AVAILABLE` 상태의 음수
  `qty_delta`만 소비/출고를 의미한다고 간주한다 — 다른 신호를 섞으면
  "출하 빈도"라는 단어의 의미가 왜곡된다.
- **area5 `wms.outbound_orders`에 대한 스키마 의존(FK, JOIN).** 위
  "정직한 전제 확인" 참고 — 향후 확장 후보로만 문서화한다.
- **실제 물리적 이동(대차/지게차 작업 배정, 이동 완료 스캔).**
  `wms_apply_slotting_recommendation`은 배정 레코드만 갱신한다 — 물리적
  이동이 실제로 일어났는지 검증하지 않는다(`wms_create_putaway_tasks`가
  "작업 완료"를 원장 반영으로 갈음한 것과 동일한 스코프 축소).
- **인력 배치·작업 지시(피커에게 이동 작업을 할당).** 인력 관리 영역
  (§5 표의 미착수 영역)의 몫이다.
- 프론트엔드 화면 구현.

## Decisions

### D1. `wms.sku_location_assignments`는 원장이 아니라 운영자 선언 레코드다

위 "정직한 전제 확인"에서 다뤘듯, 원장에 위치 축이 없으므로 "현재 위치"를
유도할 수 없다. 대안으로 이 배정을 원장처럼 이력(append-only)으로 쌓는
방법도 검토했으나, 그러면 "현재 배정이 무엇인가"를 조회할 때마다
최신 행을 찾는 쿼리가 필요해지고, `wms.purchase_orders`/`wms.receipts`
등 이 저장소의 기존 상태-보유 테이블(현재 상태를 컬럼으로 직접 갖고
`version`으로 낙관적 동시성을 거는 패턴)과 스타일이 어긋난다. 따라서
`(tenant_id, warehouse_id, product_id)`당 활성 배정 1건만 유지하는
상태-보유 테이블로 설계하고, 이전 배정으로의 변경 이력은
`wms.audit_events`(모든 쓰기 RPC가 공통으로 남기는 감사 로그)가 담당하게
한다 — 새 이력 테이블을 따로 만들지 않는다.

### D2. 등급별 목표 접근성은 하드코딩된 시스템 기본값이 아니라 창고별
정책(`wms.slotting_class_policies`)으로 관리하고, 정책이 없는 등급은
추천 생성에서 건너뛴다

`add-wcs-bottleneck-routing`의 병목 임계값 정책은 "정책이 없으면 시스템
기본 임계값을 적용"했지만(그 도메인은 큐 길이·장애 건수라는 창고와
무관하게 의미가 통하는 절대값이었다), 접근성 순위는 창고마다 위치 수와
배치가 전혀 달라 절대값 기본치가 아무 의미를 갖지 못한다(어떤 창고는
위치가 5개뿐이고 어떤 창고는 500개일 수 있다). 하드코딩된 기본값(예:
"A등급은 순위 3 이하")을 모든 창고에 동일하게 적용하면 위치 수가 적은
창고에서는 모든 위치가 "A등급 자격"을 얻어 추천이 무의미해진다. 따라서
정책이 없는 (창고, 등급) 조합은 추천 생성에서 **조용히 건너뛰고**, 그
사실을 `wms_generate_slotting_recommendations` 응답의
`skipped_no_policy_classes`에 남긴다 — 임의의 기본값을 발명해 거짓
추천을 만드는 대신, "이 창고는 아직 B등급 정책을 정의하지 않았다"는
사실을 그대로 노출한다.

### D3. 속도 계산과 추천 생성은 별도 RPC로 분리하고, 스냅샷은 매 호출마다
새로 만든다(증분/캐시 없음)

`add-wcs-bottleneck-routing`의 D1(병목 판정을 별도 집계 테이블 없이 뷰로
매번 재계산)과 같은 이유다 — 이 계약이 다루는 데이터 볼륨(창고당 SKU 수)은
트리거 기반 캐시나 증분 갱신을 정당화할 만큼 크지 않고, 매 계산마다
새 스냅샷 행을 만들면 "이 등급 판정이 언제, 어떤 윈도우로 계산됐는가"를
그대로 감사할 수 있다. 다만 병목 판정과 달리 이 계산은 뷰가 아니라
RPC로 만든다 — 뷰는 호출 시점의 "지금"만 계산할 수 있는데, 속도 계산은
호출자가 지정한 임의의 과거 윈도우(`p_window_start`/`p_window_end`)를
받아야 하고, 결과를 스냅샷 행으로 영속화해 후속 추천 생성 단계가 참조할
안정적인 `id`가 있어야 하기 때문이다. 속도 계산(`wms_compute_sku_velocity`)과
추천 생성(`wms_generate_slotting_recommendations`)을 분리한 이유는 같은
스냅샷 배치를 재사용해 정책을 바꿔가며 추천을 다시 만들어 볼 수 있게
하기 위함이다(정책 튜닝 시 원장을 다시 훑지 않아도 됨).

### D4. ABC 등급은 누적 수량 비중 기준(80/95 컷오프)으로 계산하고, 등급
경계값은 이번 스펙에서 상수로 고정한다

전통적 ABC 분석(파레토 80/20 원칙의 재고 버전)을 그대로 따른다 —
창고·윈도우 안에서 신호가 있는 SKU를 소비 수량 내림차순으로 정렬하고,
누적 수량 비중이 80%에 도달할 때까지의 SKU를 A, 80~95%를 B, 나머지를
C로 분류한다. 이 컷오프(80/95)를 창고별 설정값으로 만들지, 상수로 고정할
지 검토했으나, D2에서 이미 접근성 임계값을 정책화했으므로 두 축(등급
분류 컷오프 + 등급별 목표 접근성) 모두를 설정 가능하게 만들면 이 계약의
1차 스코프에 비해 설정 표면이 과도하게 넓어진다고 판단해, 분류 컷오프는
이번 스펙에서 상수로 고정하고 D2의 정책 테이블만 창고별로 연다. 후속
확장에서 필요하면 컷오프도 정책화할 수 있다(확장 지점).

### D5. 재배치 추천은 "위치가 배정되지 않은 고빈도 SKU"에 대해서도
생성한다(현재 위치가 `null`일 수 있다)

속도 등급은 있는데 아직 `wms.sku_location_assignments`에 배정이 없는
SKU(신규 SKU, 또는 이 스펙 도입 이전부터 있었지만 배정을 선언한 적 없는
SKU)도 실제로는 창고 어딘가에 물리적으로 존재한다 — 다만 이 스펙은 그
현재 위치를 알 방법이 없다(D1). 이런 SKU를 추천 대상에서 제외하면 "가장
먼저 슬롯팅이 필요한, 아직 아무도 관리하지 않은 SKU"가 영영 추천되지
않는다. 따라서 이런 경우 추천의 `current_location_id`는 `null`로, 사유
코드는 `UNASSIGNED_HIGH_VELOCITY`로 남기고 추천 자체는 정상 생성한다 —
승인 시 `wms_apply_slotting_recommendation`은 기존 배정을 갱신하는 대신
신규 배정을 만든다(D1의 upsert 성격).

### D6. 재배치 추천의 승인/반려는 `WMS_ADMIN`/`WAREHOUSE_MANAGER`만
할 수 있고, `PROCESS_AGENT`는 승인 권한이 없다

`add-wcs-bottleneck-routing`이 "임계값 조정과 강제 제외는 사람의 운영
판단"이라는 이유로 `PROCESS_AGENT`를 정책/제외 RPC에서 제외한 것과 같은
원칙이다. 이 스펙에서는 한 걸음 더 나아가 — 속도 계산과 추천 **생성**은
순수 분석(원장을 읽어 통계를 내는 것)이라 `PROCESS_AGENT`가 자동으로
수행해도 안전하지만, 추천을 **승인**해 실제 배정을 바꾸는 결정은 물리적
재고 이동을 유발하는 운영 판단이므로 사람 역할로 제한한다. 이는 요청서가
명시한 "보조적, 자율적이지 않음" 요구사항을 RPC 권한 수준에서 강제하는
방식이다.

### D7. `wms_apply_slotting_recommendation`은 `APPROVED` 상태의 추천만
받고, 배정 갱신과 추천 상태 전이를 하나의 트랜잭션으로 묶는다

`wms_confirm_purchase_order`가 `APPROVED` 상태의 RFQ만 받아 PO로
전환하는 패턴과 동일하다 — 승인과 적용을 분리해 두면 "승인은 했지만 아직
실제로 옮기지 않은" 중간 상태를 표현할 수 있고(예: 다음 야간 작업
윈도우까지 물리적 이동을 미루는 운영), 승인 시점과 적용 시점의 감사
기록이 분리되어 남는다.

## 데이터 모델 (검토용, 실제 DDL은 구현 단계에서 신규 마이그레이션 파일로 추가)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`은 수정하지 않는다. 이 변경의 마이그레이션은
> `wms.products`, `wms.warehouses`, `wms.stock_ledger_entries`,
> `wms.memberships`, `wms.has_role`, `wms.current_warehouse_ids`만 존재하면
> 적용할 수 있다 — 즉 기본 스키마(`20260726_wms_core_schema.sql`) 이후라면
> 다른 어떤 area의 마이그레이션 적용 여부와도 무관하다.

### `wms.storage_locations` — 보관 위치 레지스트리(신규 테이블)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `zone_code` | `text` | 자유 텍스트 구역 라벨(예: `PACK_ADJACENT`, `BULK_STORAGE`) — 계층이 아니라 라벨 |
| `location_code` | `text` | 창고 내 고유, `unique (warehouse_id, location_code)` |
| `accessibility_rank` | `int` | `> 0`, 낮을수록 접근성 좋음(운영자가 직접 매김 — 계산되지 않음) |
| `capacity_qty` | `numeric` | nullable, `>= 0` — 선택적 참고값, 용량 검증 로직 없음(Non-Goals) |
| `status` | `text` | `ACTIVE \| INACTIVE` |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.sku_location_assignments` — SKU-위치 현재 배정(신규 테이블, D1)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `product_id` | `uuid` | FK `wms.products`, `unique (warehouse_id, product_id)` — SKU당 활성 배정 1건 |
| `location_id` | `uuid` | FK `wms.storage_locations` |
| `assigned_reason` | `text` | `MANUAL_DECLARATION \| SLOTTING_RECOMMENDATION` — 이 배정이 운영자의 최초 선언인지 추천 적용 결과인지 |
| `source_recommendation_id` | `uuid` | nullable, FK `wms.slotting_recommendations` — 추천 적용으로 생긴 배정이면 채움 |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.slotting_class_policies` — 등급별 목표 접근성 정책(신규 테이블, D2)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `velocity_class` | `text` | `A \| B \| C`, `unique (warehouse_id, velocity_class)` |
| `max_accessibility_rank` | `int` | `> 0` — 이 등급 SKU가 있어야 할 접근성 순위 상한 |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.sku_velocity_snapshots` — SKU별 출하 속도 스냅샷(신규 테이블, D3/D4)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK — 추천 생성이 참조하는 "배치 id" 역할도 겸함 |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `product_id` | `uuid` | FK `wms.products` |
| `window_start` / `window_end` | `date` | 계산에 사용한 관찰 윈도우 |
| `outbound_qty` | `numeric` | 윈도우 내 `AVAILABLE` 상태 음수 `qty_delta` 절대값 합계 |
| `outbound_event_count` | `int` | 같은 조건의 원장 행 건수 |
| `velocity_class` | `text` | `A \| B \| C` — D4의 누적 비중 컷오프로 계산 |
| `computed_at` | `timestamptz` | |
| `computed_by` | `uuid` | 계산을 요청한 actor |
| `batch_id` | `uuid` | 같은 `wms_compute_sku_velocity` 호출에서 생성된 스냅샷들을 묶는 값(응답의 `batch_id`와 동일) |

`outbound_event_count = 0`인 SKU는 이 테이블에 행을 만들지 않는다(위
"정직한 전제 확인" — 신호 없는 SKU는 명시적으로 제외).

### `wms.slotting_recommendations` — 재배치 추천(신규 테이블, D5/D6/D7)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `product_id` | `uuid` | FK `wms.products` |
| `velocity_snapshot_id` | `uuid` | FK `wms.sku_velocity_snapshots` — 이 추천의 근거 |
| `current_location_id` | `uuid` | nullable, FK `wms.storage_locations` — D5, 배정 없으면 `null` |
| `recommended_location_id` | `uuid` | FK `wms.storage_locations` |
| `reason_code` | `text` | `RELOCATE_UNDERSERVED \| UNASSIGNED_HIGH_VELOCITY` |
| `status` | `text` | `PENDING \| APPROVED \| REJECTED \| APPLIED \| EXPIRED` |
| `reviewed_by` / `reviewed_at` | | nullable |
| `review_reason` | `text` | nullable — 반려 사유 등 |
| `applied_at` | `timestamptz` | nullable |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |

### `wms.slotting_recommendation_overview_v` — 조회 전용 뷰

`wms.slotting_recommendations`에 제품(`sku`, `name`), 현재/추천 위치의
`location_code`/`accessibility_rank`, 스냅샷의 `velocity_class`/
`outbound_qty`를 조인한 읽기 전용 뷰. `security invoker`로 정의해 기반
테이블의 RLS를 그대로 상속한다(area4의 두 뷰와 동일한 패턴).

## RPC 계약 (검토용 시그니처 초안)

모든 RPC는 `language plpgsql security definer set search_path = wms,
public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only), `wms.audit_events`
기록을 따른다. 성공 시 공통 봉투 `{result: 'ok', document_id, status,
version, next_actions, warnings?}`를 반환한다.

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_register_storage_location` | `p_tenant_id, p_warehouse_id, p_zone_code, p_location_code, p_accessibility_rank, p_capacity_qty default null, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | 중복 `(warehouse_id, location_code)`면 `INVALID:` |
| `wms_set_storage_location_status` | `p_location_id, p_status, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | `ACTIVE <-> INACTIVE`만 허용 |
| `wms_assign_sku_location` | `p_tenant_id, p_warehouse_id, p_product_id, p_location_id, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `INBOUND_OPERATOR` | 이미 활성 배정이 있으면 `INVALID:`(재배정은 아래 RPC) |
| `wms_reassign_sku_location` | `p_assignment_id, p_location_id, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `INBOUND_OPERATOR` | `assigned_reason='MANUAL_DECLARATION'`으로 갱신 |
| `wms_register_slotting_class_policy` | `p_tenant_id, p_warehouse_id, p_velocity_class, p_max_accessibility_rank, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | 중복 `(warehouse_id, velocity_class)`면 `INVALID:` |
| `wms_update_slotting_class_policy` | `p_policy_id, p_max_accessibility_rank, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | |
| `wms_compute_sku_velocity` | `p_tenant_id, p_warehouse_id, p_window_start, p_window_end, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `PROCESS_AGENT` | `p_window_start < p_window_end` 검증. 응답에 `batch_id`, `included_product_count`, `skipped_no_data_count` 포함 |
| `wms_generate_slotting_recommendations` | `p_tenant_id, p_warehouse_id, p_velocity_batch_id, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `PROCESS_AGENT` | 응답에 `generated_count`, `skipped_no_policy_classes`, `skipped_already_optimal_count` 포함 |
| `wms_review_slotting_recommendation` | `p_recommendation_id, p_decision, p_actor_id, p_idempotency_key, p_expected_version, p_review_reason default null, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | `p_decision in ('APPROVE','REJECT')`. `PENDING`이 아니면 `INVALID:` |
| `wms_apply_slotting_recommendation` | `p_recommendation_id, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `INBOUND_OPERATOR` | `APPROVED`가 아니면 `INVALID:`. 배정 갱신(D1)과 추천 상태 전이(D7)를 한 트랜잭션으로 처리 |

`wms_compute_sku_velocity`와 `wms_generate_slotting_recommendations`가
`PROCESS_AGENT`를 허용하는 이유(순수 분석은 자동화 가능, 승인/적용은
사람 전용)는 D6 참고.

## 역할 모델

새 역할을 추가하지 않는다. 기존 역할 재사용:

| 역할 | 이 계약에서의 권한 |
|---|---|
| `WMS_ADMIN` | 모든 RPC 호출 가능 |
| `WAREHOUSE_MANAGER` | 위치/정책 관리, 배정 선언·재배정, 속도 계산·추천 생성, **추천 승인/반려**, 승인된 추천 적용 |
| `INBOUND_OPERATOR` | 배정 선언·재배정, 승인된 추천 적용(물리적 이동을 실제로 수행하는 역할 — `wms_create_putaway_tasks`와 동일한 성격) — 위치/정책 관리와 추천 승인/반려는 불가 |
| `PROCESS_AGENT` | 속도 계산, 추천 생성만 가능(D6) — 승인/반려/적용/위치·정책 관리는 불가 |
| (모든 테넌트/창고 멤버) | `wms.slotting_recommendation_overview_v` 등 조회 전용 뷰·테이블 읽기 |

## RLS 패턴

기존 테이블과 동일하게, 신규 5개 테이블 모두:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer`
  RPC를 통해서만 이루어진다(기존 관례와 동일).

## MCP 도구 노출

`mcp/wms_mcp/mcp_server.py`에 위 10개 RPC를 감싸는 `@mcp.tool` 함수를
1:1로 추가한다. `docs/03-processgpt-integration.md`의 에이전트 tool
허용 목록에는 `PROCESS_AGENT`를 `compute_sku_velocity`,
`generate_slotting_recommendations`(읽기·분석 성격)에만 추가하고, 승인/
적용/위치·정책 관리 도구에는 추가하지 않는다(역할 모델과 동일한 원칙).

## 확장 지점

- **`wms_master-data`로의 위치 모델 승격**: 이 스펙의
  `wms.storage_locations`가 평평한 레지스트리에서 통로·선반·빈 단위 계층,
  용량 관리 규칙 엔진으로 확장될 필요가 생기면, `wms_master-data`가 그
  전체 모델을 흡수하고 이 스펙은 `accessibility_rank`만 참조하는 방향으로
  재정렬될 수 있다.
- **area5 `wms.outbound_orders`를 보조 신호로 통합**: area5가 이
  데이터베이스에 적용된 환경이라면, `wms_compute_sku_velocity`의 신호
  소스에 `wms.outbound_orders.status='COMPLETED'` 행을 UNION하는 후속
  변경을 검토할 수 있다 — 이번 변경은 그 가능성만 남기고 스키마 의존은
  만들지 않는다(위 "정직한 전제 확인" 참고).
- **인력 관리 영역과의 연결**: 승인된 추천의 물리적 이동을 실제 작업자에게
  배정·추적하는 것은 인력 관리 영역(§5 표 미착수)의 몫이다 —
  `wms.slotting_recommendations.status='APPROVED'`를 그 영역이 소비할 수
  있는 신호로 남긴다.
- **속도 계산 신호 확장**: 등급 분류 컷오프(D4, 현재 80/95 상수)를
  창고별 정책으로 여는 것, `outbound_event_count`(건수) 기준 분류를
  `outbound_qty`(수량) 기준과 별도로 제공하는 것.
- **프론트엔드**: `frontend/`에 `/inventory/slotting` 라우트(속도 등급
  대시보드, 추천 검토 큐)를 추가하는 후속 변경 — 이번 변경에는 화면
  구현이 포함되지 않는다.

## Risks

- **속도 신호가 실제로 채워지기 전까지는 이 계약의 추천 생성이 항상
  빈 결과를 반환한다.** 이는 결함이 아니라 이 저장소의 정직한 현재
  상태다(위 "정직한 전제 확인"). E2E 검증은 신호를 인위적으로 주입하는
  시드 데이터로 이 사실을 우회하지 않고, "신호가 없을 때의 정직한 동작"
  자체를 시나리오로 검증한다(spec.md 참고).
  향후 소비/출고 RPC(정식 `wms_outbound-fulfillment`)가 구현되면 이
  계약의 신호는 자동으로 채워지기 시작한다 — 이 계약 자체를 수정할
  필요가 없다.
- **접근성 순위는 운영자의 주관적 판단값이다.** 시스템이 실제 창고
  도면이나 동선을 계산해 검증하지 않는다 — 잘못 매겨진 순위는 잘못된
  추천으로 이어질 수 있다. 이는 Non-Goals에서 이미 인정한 스코프 축소다.
- **`wms.sku_location_assignments`가 물리적 적치와 자동 동기화되지
  않는다.** 운영자가 배정을 선언/승인하고도 실제로 SKU를 옮기지 않으면
  배정 레코드와 물리적 현실이 어긋날 수 있다 — 이 계약은 그 어긋남을
  감지하지 못한다(실사/`wms_cycle-counting` 영역이 다룰 문제).
