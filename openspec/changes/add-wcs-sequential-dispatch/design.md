## Context

`docs/04-wms-wcs-market-feature-catalog.md`(§2.3, §3)가 정리한 "서열 출고/지능형
적재"는 Dematic iQ("15개 로봇 셀 연동, 최대 28종 패키지 혼합 적재, Store-based
순서 적재, 중량/용적 최적화 및 자동 스트레치 필름 포장 연동")와
두산로지스틱스솔루션("보관 위치별 정밀 재고 관리, 서열 출고 제어") 두 벤더가
공통으로 다루는 영역이다. 두 벤더 설명 모두 "이미 확정된 출고 단위를 어떤
순서로, 어떤 로봇 셀에, 어떤 팔레트로 실을 것인가"를 다루지 "그 출고 단위가
어떻게 만들어지는가"(주문 접수, 재고 할당, 피킹)는 상세히 다루지 않는다 — 서열
출고는 출고 이행 파이프라인의 **마지막 단계**에 가깝다.

### Option A/B 결정과 근거

proposal.md "Why"에서 이미 결론을 냈듯, 이 설계는 **Option A**(최소 출고 골격 +
서열/적재 계층)를 채택한다. Option B(순수 `linked_entity_type`/`linked_entity_id`
opaque 참조)를 기각한 이유는 다음과 같다:

1. **테스트 불가능한 스펙이 된다.** Option B는 "서열이 매겨진 대상이 존재한다"고
   가정하지만, 그 대상을 만드는 RPC나 상태 전이가 이 변경 안에 전혀 없다.
   spec.md의 Given 절이 항상 "어딘가에 이미 존재하는 `linked_entity_id`"를
   전제해야 하는데, 그 전제를 만들 수단이 스펙 밖에 있으면 E2E가 실제로 왕복
   검증할 수 없는 참조가 된다.
2. **area1의 D6(느슨한 참조) 원칙과 모순되지 않으면서도 더 정직하다.** area1의
   D6는 "값의 의미를 해석하고 반응하는 것은 각 소비 스펙의 책임"이라고 이미
   명시했다 — 이 변경이 그 책임을 다하려면 최소한 그 값이 무엇을 가리키는지
   정의하는 테이블이 있어야 한다.
3. **main repo `wms_outbound-fulfillment`의 6개 Requirement를 통째로 가정하는
   것도 아니다.** 이 변경은 그중 "주문 접수"(WMS-OUT-001)의 극히 축소된 형태
   하나만 가져온다 — 할당/예약/피킹/포장/출하/취소(WMS-OUT-002~006)는 전부
   제외한다(아래 Non-Goals). 즉 Option A를 선택했다고 해서 출고 이행 전체를
   구현하는 것이 아니라, "서열을 매길 수 있는 최소한의 대상"만 만든다.

### 정직한 전제 확인 (구현 상태와 의존성의 성격)

- **area1~4 전부 아직 구현되지 않았다.** `supabase/migrations/`에 해당
  마이그레이션 파일이 없다. 이 설계가 참조하는 `wms.equipment`,
  `wms.equipment_commands`, `wms.equipment_status_events`, `wms.dispatch_waves`,
  `wms.work_orders`, `wms.wcs_routing_policies` 등은 각 스펙의 design.md에
  있는 **검토용 후보**이며, 실제 DB에는 존재하지 않는다.
- **이 변경의 실제 DB 의존성은 area1 전체와, area2의 `wms.dispatch_waves`
  테이블에만 있다.** `wms.dispatch_sequences.wave_id`가 `wms.dispatch_waves`를
  참조하지만, area2의 `wms.work_orders`는 전혀 참조하지 않는다(D1이 이유를
  설명). area3(`wms.sortation_profiles`), area4(`wms.wcs_routing_policies`,
  `wms.wcs_routing_overrides`, 두 뷰)에는 스키마 의존성이 없다 — `SORTER`/
  `CONVEYOR` 전용 개념과 병목 판정은 `ROBOT_CELL` 대상 적재와 도메인이 다르다.
  따라서 이 변경의 마이그레이션은 area1과 area2의 `wms.dispatch_waves`
  부분이 적용된 뒤라면, area2의 `wms.work_orders`·area3·area4 적용 여부와
  무관하게 적용할 수 있다.
- **이 저장소에는 handling unit(HU)/카톤 바코드 테이블도, 제품 중량/용적
  마스터데이터도 없다.** `wms.products`는 `sku`, `name`, `uom`,
  `reorder_min/max`만 가진다 — 카탈로그의 "포장 규격(Packaging Specification)
  관리"(§2.1)에 해당하는 중량/용적 컬럼이 없다. area3의 D6이 카톤 스캔
  식별자를 참조 무결성 없는 자유 텍스트로 둔 것과 같은 이유로, 이 계약은
  중량/용적을 `wms.products`에 새 컬럼을 추가해 강제하지 않고, 호출자가
  `wms.outbound_orders` 등록 시 선언한 값(`declared_weight_kg`,
  `declared_volume_l`, 둘 다 nullable)으로만 다룬다. 실제 계근·용적 측정
  마스터데이터 정비는 이 변경보다 넓은 스코프(`wms_master-data`의
  포장 규격 확장)이므로 범위 밖에 남긴다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블/RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

## Goals / Non-Goals

**Goals:**

- 최소 범위의 출고 단위(제품·수량·매장/배송처·희망 납기·선언 중량/용적)를
  등록하는 계약 — main repo `wms_outbound-fulfillment`의 극히 축소된 부분집합.
- area2의 디스패치 웨이브 안에서 출고 단위에 `sequence_position`(서열 위치)과
  `target_pallet_code`(목표 팔레트 그룹)를 배정하는 계약.
- area1의 명령 봉투 위에서 `ROBOT_CELL` 설비를 대상으로 한 혼합 팔레타이징
  (`PALLETIZE`) 명령의 구조화된 `payload`(서열 아이템 목록, 팔레트 단위
  중량/용적 상한) 계약과, 디스패치 시점의 선언값 기준 상한 검증.
- 팔레타이징 결과(성공/부분 적재/중량 초과/용적 초과/중단)를 area1의 "명령
  결과 보고" 계약에 매핑하고, 결과의 항목별 배열(`loaded_items`)을 파싱해
  각 서열 배정 건의 상태를 개별적으로 되돌리는 완료 전파.
- 자동 스트레치 필름 포장(`WRAP`)을 위한 얇은 명령 payload 확장 — 카탈로그의
  "자동 스트레치 필름 포장 연동"을 문자 그대로 만족시키되, 실제 포장 장비
  프로토콜은 다루지 않는다.
- 완성된 팔레트의 구성(어느 서열 아이템이 어느 위치에 실렸는지)을 조회할 수
  있는 팔레트 매니페스트 계약.
- 후속 영역(디지털 트윈/시뮬레이션, area6)이 이 계약을 다시 만들지 않고
  그 위에 얹을 수 있는 확장 지점.

**Non-Goals:**

- **재고 할당/예약(FIFO/FEFO, lot/serial 제약).** main repo
  `wms_outbound-fulfillment`의 WMS-OUT-002. 이 계약의 `wms.outbound_orders`는
  등록 시점에 재고 가용성을 검증하지 않는다 — 이는 별도의 향후
  `wms_outbound-fulfillment` 스펙의 몫이다.
- **Wave 기반 피킹 작업 생성, 스캔 기반 피킹.** WMS-OUT-003, WMS-OUT-004.
  이 계약은 "이미 확정된 출고 단위를 어떤 순서로 로봇 셀에 보낼지"만 다룬다 —
  그 출고 단위가 실제로 피킹되어 물리적으로 준비되었는지는 검증하지 않는다.
- **포장·출하 확정과 원장 차감.** WMS-OUT-005. `wms.stock_ledger_entries`를
  갱신하지 않는다 — 이 계약의 `wms.outbound_orders.status`는 재고 이동을
  반영하는 것이 아니라 서열/적재 진행 상태만 추적한다.
- **출고 취소·복원의 재고 측 효과.** WMS-OUT-006. 이 계약의 취소는 서열
  배정과 설비 명령만 취소한다 — 예약 재고를 복원하는 절차는 이 계약에 없다
  (애초에 이 계약이 예약을 만들지 않으므로).
- **서열 위치(`sequence_position`)와 목표 팔레트(`target_pallet_code`)를
  계산하는 최적화 알고리즘.** 매장 진열 순서 최적화, 배송 경로 최적화,
  중량/용적을 고려한 자동 팔레트 배분(bin packing)은 다루지 않는다 — 이
  계약은 호출자(사람 운영자 또는 향후 계획 엔진)가 이미 결정한 서열 값을
  받아 저장·검증·디스패치할 뿐이다. area2의 D6("Wave는 최소 데이터 계약만
  제공한다")와 동일한 원칙이다.
- **병목 예측, 로봇 셀 간 실시간 부하 분산.** area4가 이미 이 영역을 다뤘고,
  이 계약은 area4를 필수 의존성으로 삼지 않는다(D9).
- **실제 로봇 팔 협조 제어, 물리적 그리퍼 시퀀싱, 실제 스트레치 필름 장비
  프로토콜.** `wms_wcs-equipment-control`이 이미 그은 "실제 PLC/필드버스
  제어는 범위 밖" 경계와 동일하다.
- **HU/카톤 바코드 모델 신설, `wms.products` 중량/용적 마스터데이터 신설.**
  이 저장소에 없는 개념을 이 변경에서 새로 만들지 않는다(위 "정직한 전제
  확인" 참고).
- **디지털 트윈 시뮬레이션 엔진.** 후속 스펙(area6)에서 다룬다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 서열 배정은 area2의 `wms.work_orders`를 재사용하지 않고, 새 엔티티
`wms.dispatch_sequences`로 만든다

area1 design.md의 확장 지점 표는 "`work_order.linked_entity_type`에
`'outbound_wave'` 같은 새 값을 추가하고, `command_payload`에 적재 순서
인덱스를 담아 area2의 Wave 큐잉·릴리즈를 그대로 재사용한다"고 예견했다. 이
설계는 그 경로를 따르지 않는다 — `wms.work_orders`는 "업무 오더 1건 : 설비
명령 1건(현재 구현)"이라는 1:1에 가까운 형태로 설계되었고(area2 D1), 명령
`payload`도 단일 오더의 세부값만 담는다. 그러나 `PALLETIZE` 명령은 본질적으로
**배치**다 — 혼합 팔레트 하나에 여러 출고 단위(서로 다른 매장/제품일 수 있음)가
같은 로봇 셀 명령 한 번으로 실린다. 이를 `work_order`로 표현하려면 "여러
업무 오더가 설비 명령 하나를 공유한다"는, area2가 지금까지 다루지 않은
N:1 관계를 새로 정의해야 한다. 반면 `wms.dispatch_sequences`를 독립 엔티티로
두면:

- 각 출고 단위(→ 서열 배정 1건)가 자신의 `sequence_position`, `target_pallet_code`,
  개별 완료/실패 상태를 갖는 자연스러운 N:1(서열 배정 N : 설비 명령 1) 모델이
  된다.
- area2의 스펙 문구(work order는 1건의 명령을 가리킨다)를 전혀 건드리지
  않아도 된다 — area4가 area2의 Requirement를 감싸되 수정하지 않은 것과
  같은 원칙.

트레이드오프: area1이 예견한 확장 경로와 다른 선택이다. 이는 area1의
확장 지점 표가 "가능한 방향 중 하나"를 제시한 것이지 강제한 계약은
아니라는 점(그 표 자체가 "가칭"이라고 명시)에 근거해 정당화한다.

### D2. `wms.outbound_orders`는 header/lines로 나누지 않고, `wms.purchase_orders`와
같은 방식으로 "제품 1건 = 행 1건"으로 평탄화한다

main repo `wms_outbound-fulfillment`는 주문(header)과 라인을 분리하는 모델을
전제하지만, 이 저장소의 기존 입고 측 구현은 이미 `wms.purchase_orders`에서
"RFQ와 PO를 하나의 상태 전이로 단순화"하고(`docs/02-contracts.md` 1.3),
제품 하나당 행 하나로 평탄화하는 선례를 남겼다. 이 계약은 그 선례를 따른다 —
`wms.outbound_orders`의 한 행이 "특정 매장으로 갈 특정 제품·수량"을 의미하며,
여러 제품을 한 주문으로 묶는 header 개념은 만들지 않는다. 여러 제품이 같은
목적지(매장)로 갈 때는 `store_code`가 같은 여러 행으로 표현되고, 그 행들을
같은 팔레트로 묶는 것은 `target_pallet_code`(D3)가 담당한다 — header 없이도
"같은 팔레트에 실릴 항목들의 묶음"을 표현할 수 있다.

### D3. `target_pallet_code`는 서열 배정 시점(계획)에 호출자가 지정하고, 실제
디스패치는 그 값으로 그룹핑된 배치를 만든다

"어떤 항목들이 같은 팔레트에 실릴지"를 결정하는 것은 이 계약의 책임이 아니다
(Non-Goals의 최적화 알고리즘 제외). 대신 계약은 그 결정을 **입력**으로 받는
슬롯(`target_pallet_code`)만 제공한다. `wms_dispatch_palletize_command`는
같은 `(wave_id, target_pallet_code)`를 가진 `QUEUED` 상태의
`wms.dispatch_sequences` 전부를 모아 `sequence_position` 순으로 정렬한
배열을 만들어 단일 `PALLETIZE` 명령의 `payload.sequence_items`로 싣는다.
이렇게 하면 "혼합 팔레타이징"(여러 출고 단위가 한 팔레트에)이 명령 하나로
자연스럽게 표현된다.

### D4. `PALLETIZE` 명령의 대상 설비(`equipment_id`)는 호출자가 명시적으로
지정하고, 자동 부하 분산 대상이 아니다

area2/area4는 "가용 설비 후보 중 최적을 자동 선택"하는 모델이다. 이 계약은
그 모델을 `PALLETIZE`에는 적용하지 않는다 — 물리적으로 하나의 혼합 팔레트는
동일한 로봇 셀에서 처음부터 끝까지 쌓여야 하며, 항목마다 부하 분산으로 다른
셀에 보내면 "하나의 팔레트"라는 개념 자체가 깨진다. 따라서
`wms_dispatch_palletize_command`는 `p_equipment_id`를 필수 파라미터로 받고,
그 설비가 `ROBOT_CELL` 타입이고 `IDLE` 또는 이미 같은 `target_pallet_code`를
쌓고 있는 `RUNNING` 상태인지만 검증한다(area4의 "가용 설비 선택" 자동화는
이 계약의 필수 의존성이 아니다 — D9 확장 지점 참고, 향후 "이 셀 배정 자체를
자동화"하는 후속 확장은 열어 둔다).

### D5. 팔레타이징 결과는 `command_type='DIVERT'`(area3)처럼 `detail.outcome`
필드로 표현하되, 항목 단위 배열(`loaded_items`)을 추가로 요구한다

area3의 D4(outcome/명령 상태 정합성 검증)를 그대로 재사용한다 —
`outcome in ('SUCCESS','PARTIAL')`이면 `command_status='COMPLETED'`만,
`outcome in ('OVERWEIGHT','OVERVOLUME','ABORTED')`이면
`command_status='FAILED'`만 허용된다. 그러나 area3의 `DIVERT`는 명령 하나가
아이템 하나를 대상으로 하므로 outcome 하나로 충분했다. `PALLETIZE`는 명령
하나가 여러 서열 배정 건을 대상으로 하므로(D3), 전체 outcome과 별개로
`detail.loaded_items`(각 항목의 `dispatch_sequence_id`, `load_position`,
`item_outcome`: `LOADED`/`SKIPPED`)를 요구한다. 전체 `outcome='PARTIAL'`은
일부 항목이 `SKIPPED`되었지만 명령 자체는 완료로 보고되는 현실적 상황(예:
한 항목이 중량 초과로 제외되고 나머지는 정상 적재)을 표현한다.

### D6. 항목 단위 완료 전파는 `wms.equipment_status_events`에 대한
`AFTER INSERT` 트리거로 구현하고, area2의 D2(명령 단위 전파)를 항목 단위로
일반화한다

area2 D2는 `wms.equipment_commands`의 `AFTER UPDATE OF status` 트리거로
"명령 1건 → 업무 오더 1건" 전파를 구현했다. 이 계약은 명령 1건이 여러 서열
배정 건에 영향을 주므로(D3), 같은 원리를 `detail.loaded_items` 배열을
`jsonb_array_elements`로 순회하며 각 `dispatch_sequence_id`에 대해 개별
`UPDATE`를 실행하는 형태로 확장한다. 트리거는 `wms.equipment_commands`가
아니라 `wms.equipment_status_events`(이벤트가 이미 `detail`을 담고 있으므로)
에 건다 — area3의 D4/D5 검증 트리거와 같은 테이블, 같은 시점(`AFTER INSERT`)을
공유하되 별도 트리거 함수로 분리한다(관심사 분리 — 하나는 정합성 검증,
하나는 상태 전파).

### D7. 중량/용적 상한 검증은 디스패치 시점(선언값 합계 vs 상한)과 결과
보고 시점(outcome) 두 곳에서 이루어지되, 서로 다른 목적을 가진다

`wms_dispatch_palletize_command`는 배치를 구성할 때 각 항목의
`declared_weight_kg`/`declared_volume_l`(D2, `wms.outbound_orders`) 합계가
호출자가 지정한 `p_max_weight_kg`/`p_max_volume_l`을 넘으면 `INVALID:`로
거부한다 — 이는 "애초에 계획이 잘못된 배치를 로봇 셀에 보내지 않는다"는
사전 검증이다. 반면 `outcome='OVERWEIGHT'`/`'OVERVOLUME'`은 설비가 실제
계근/체적 측정 후 선언값과 실측값이 달라 상한을 넘긴 경우를 보고하는
사후 결과다 — 두 시점 모두 검증하는 것은 중복이 아니라, "계획 단계의 실수"와
"실측 단계의 편차"라는 서로 다른 실패 원인을 구분해서 관찰 가능하게 하기
위함이다(카탈로그의 "중량/용적 최적화"를 이 두 지점으로 나눠 만족시킨다).

### D8. `WRAP` 명령은 `PALLETIZE`와 달리 `wms.dispatch_sequences`에 아무
영향도 주지 않는 얇은 확장으로 둔다

카탈로그의 "자동 스트레치 필름 포장 연동"을 만족시키기 위해 `command_type`
열린 집합에 `WRAP`을 추가하지만(area1 D7, area3 D2와 동일한 확장 방식),
`WRAP`은 이미 완성된 팔레트(`pallet_code`) 전체를 대상으로 하는 후속 공정이다
— 개별 서열 배정 건과 매핑되지 않는다. 따라서 `WRAP`의 `payload`(`pallet_code`,
`wrap_program`)와 결과 `detail`(`outcome: SUCCESS/FAILED`, `wrap_cycles`)은
검증 트리거(구조 확인만, area3의 `DIVERT`/`SET_SPEED`처럼 경량)를 갖지만,
D6과 같은 완료 전파 로직을 얹지 않는다 — `WRAP` 결과는 `wms.equipment_status_events`
조회로 확인하는 것으로 충분하고, 그 이상의 상태 모델을 이 변경에서 만들지
않는다(실제 포장 장비 프로토콜 자체도 Non-Goals).

### D9. area4(`wms_wcs-bottleneck-routing`)를 필수 의존성으로 삼지 않는다

D4에서 설명했듯 `PALLETIZE`의 대상 설비는 호출자가 명시적으로 지정한다 —
area4의 `wms.wcs_select_available_equipment`가 하는 "여러 후보 중 자동
선택"은 이 계약에 맞지 않는다(하나의 팔레트는 한 셀에서 끝까지 쌓여야
하므로). 따라서 이 변경은 area4의 테이블/함수를 전혀 참조하지 않고, area1만
있으면 독립적으로 동작한다. 다만 "어떤 로봇 셀에 새 팔레트 빌드를 시작할지"
결정하는 향후 확장(현재는 순수 호출자 판단)이 area4의 병목 회피 신호를
참고하도록 만드는 것은 자연스러운 후속 통합이며, 확장 지점 표에 남긴다.

## 데이터 모델 (검토용 후보)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은 구현 단계에서
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`과 area1/area2의 마이그레이션은 수정하지
> 않으며, area1 전체와 area2의 `wms.dispatch_waves` 부분이 먼저 적용된
> 뒤에만 이 변경의 마이그레이션을 적용할 수 있다.

### `wms.outbound_orders` — 최소 출고 단위 (신규 테이블, D2)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `order_number` | `text` | 외부/수동 참조 번호(중복 허용 — dedup은 `idempotency_key`가 담당) |
| `store_code` | `text` | 매장/배송처 식별자(카탈로그의 "매장 진열 순서") |
| `product_id` | `uuid` | FK `wms.products` |
| `qty` | `numeric` | `> 0` |
| `requested_delivery_date` | `date` | nullable |
| `declared_weight_kg` | `numeric` | nullable, `>= 0` — 호출자 선언값(정직한 전제 확인 참고, `wms.products`에 마스터데이터 없음) |
| `declared_volume_l` | `numeric` | nullable, `>= 0` |
| `status` | `text` | `OPEN \| SEQUENCED \| DISPATCHED \| COMPLETED \| FAILED \| CANCELLED` |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.dispatch_sequences` — 웨이브 내 서열 배정 (신규 테이블, D1)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `outbound_order_id` | `uuid` | FK `wms.outbound_orders`, unique — 출고 단위당 활성 서열 배정 1건만 |
| `wave_id` | `uuid` | FK `wms.dispatch_waves`(area2) |
| `sequence_position` | `int` | `> 0`, unique `(wave_id, sequence_position)` |
| `target_pallet_code` | `text` | 목표 팔레트 그룹(D3), not null |
| `status` | `text` | `QUEUED \| DISPATCHED \| COMPLETED \| FAILED \| CANCELLED` |
| `equipment_command_id` | `uuid` | FK `wms.equipment_commands`(area1), nullable, `PALLETIZE` 디스패치 성공 후에만 채움 |
| `load_position` | `int` | nullable — 결과 보고로 채워지는 실제 적재 위치(계획한 `sequence_position`과 다를 수 있음) |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.equipment_commands.command_type` — `CHECK` 제약 확장

```sql
alter table wms.equipment_commands
  drop constraint equipment_commands_command_type_check; -- 실제 제약명은 area1 적용 후 확인
alter table wms.equipment_commands
  add constraint equipment_commands_command_type_check
  check (command_type in (
    'MOVE','LOAD','UNLOAD','START','STOP','RESET','HOLD','RESUME',
    'DIVERT','SET_SPEED',
    'PALLETIZE','WRAP'
  ));
```

area3가 이미 `DIVERT`/`SET_SPEED`를 추가했으므로, 이 변경의 마이그레이션은
area3 이후(또는 area3 없이 area1 이후) 시점의 실제 제약명을 확인해 반영해야
한다(tasks.md 0장).

### `PALLETIZE` 명령 `payload` 구조 (계약, 새 컬럼 아님)

```json
{
  "target_pallet_code": "PLT-2026-0001",
  "max_weight_kg": 250,
  "max_volume_l": 500,
  "sequence_items": [
    {
      "dispatch_sequence_id": "…",
      "sequence_position": 1,
      "outbound_order_id": "…",
      "declared_weight_kg": 4.2,
      "declared_volume_l": 3.1
    }
  ]
}
```

- `target_pallet_code`(text, 필수): D3.
- `max_weight_kg` / `max_volume_l`(numeric, 선택): 지정 시 `sequence_items`의
  선언값 합계가 이를 넘으면 디스패치 자체가 `INVALID:`(D7).
- `sequence_items`(array, 필수, 최소 1건): `sequence_position` 오름차순으로
  정렬되어 있어야 한다.

### `WRAP` 명령 `payload` 구조 (계약, 새 컬럼 아님, D8)

```json
{ "pallet_code": "PLT-2026-0001", "wrap_program": "STANDARD" }
```

- `pallet_code`(text, 필수), `wrap_program`(text, 필수): `STANDARD \| HEAVY`.

### `wms_report_command_result`의 `p_detail` 구조 — `PALLETIZE` 결과 (계약, D5)

```json
{
  "outcome": "PARTIAL",
  "total_actual_weight_kg": 182.4,
  "total_actual_volume_l": 340.0,
  "loaded_items": [
    { "dispatch_sequence_id": "…", "load_position": 1, "item_outcome": "LOADED" },
    { "dispatch_sequence_id": "…", "load_position": null, "item_outcome": "SKIPPED", "reason": "OVERWEIGHT" }
  ]
}
```

| `outcome` | 허용되는 `p_command_status` | 개별 `item_outcome` 허용값 |
|---|---|---|
| `SUCCESS` | `COMPLETED`만 | `LOADED`만 |
| `PARTIAL` | `COMPLETED`만 | `LOADED`, `SKIPPED` 혼재 가능 |
| `OVERWEIGHT` / `OVERVOLUME` / `ABORTED` | `FAILED`만 | 전부 `SKIPPED`(D5) |

`wms_report_command_result`의 `p_detail` 구조 — `WRAP` 결과(D8):

```json
{ "outcome": "SUCCESS", "wrap_cycles": 3 }
```

`outcome in ('SUCCESS')`은 `COMPLETED`만, `outcome='FAILED'`는 `FAILED`만
허용한다(구조 검증만, 완료 전파 없음).

## RPC 계약 (검토용 시그니처 초안)

모든 RPC는 기존과 동일하게 `language plpgsql security definer set search_path =
wms, public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only)를 따른다. `PALLETIZE`/`WRAP`
결과 보고는 새 RPC를 만들지 않고 area1의 `wms_report_command_result`를 그대로
사용한다(area3 선례).

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_create_outbound_order` | `p_tenant_id, p_warehouse_id, p_order_number, p_store_code, p_product_id, p_qty, p_requested_delivery_date default null, p_declared_weight_kg default null, p_declared_volume_l default null, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `PROCESS_AGENT`, `WMS_ADMIN` | `status='OPEN'` |
| `wms_assign_dispatch_sequence` | `p_outbound_order_id, p_wave_id, p_sequence_position, p_target_pallet_code, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`, `WMS_ADMIN` | `expected_version`은 출고 단위 버전. 대상 웨이브가 `OPEN`이 아니면 `INVALID:`(area2 패턴). `outbound_order.status`를 `SEQUENCED`로 전이 |
| `wms_cancel_dispatch_sequence` | `p_dispatch_sequence_id, p_actor_id, p_idempotency_key, p_expected_version, p_reason default null` | 위와 동일 | `DISPATCHED`면 연결된 설비 명령도 취소 시도(area2 취소 패턴과 동일) |
| `wms_dispatch_palletize_command` | `p_tenant_id, p_warehouse_id, p_equipment_id, p_wave_id, p_target_pallet_code, p_max_weight_kg default null, p_max_volume_l default null, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`, `WMS_ADMIN` | `expected_version`은 설비 버전(area1과 동일 의미). 내부적으로 `wms_dispatch_equipment_command` 호출(D3, D4, D7) |
| `wms_get_dispatch_sequence_status` | `p_tenant_id, p_warehouse_id, p_wave_id default null, p_outbound_order_id default null` | 모든 테넌트/창고 멤버(읽기) | 서열 배정 + 연결된 설비 명령 상태 + 출고 단위 정보를 조인한 조회 전용 함수 |
| `wms_get_pallet_manifest` | `p_tenant_id, p_warehouse_id, p_equipment_command_id default null, p_target_pallet_code default null` | 모든 테넌트/창고 멤버(읽기) | `wms.equipment_status_events`의 `PALLETIZE` 결과 `detail.loaded_items`를 파싱해 서열 배정과 조인한 조회 전용 함수 |

모든 쓰기 RPC는 성공 시 `{result: 'ok', document_id, status, version,
next_actions, warnings?}` 형태를 반환하고, `wms.audit_events`에
`entity_type in ('outbound_order', 'dispatch_sequence')` 레코드를 남긴다.

### 항목 단위 완료 전파 메커니즘 (구현 검토용, D6)

새 RPC가 아니라, area1이 소유한 `wms.equipment_status_events`에 추가하는
`AFTER INSERT` 트리거로 구현한다. 트리거는 `NEW.event_type in
('COMMAND_COMPLETED', 'COMMAND_FAILED')`이고 연결된 명령의
`command_type='PALLETIZE'`일 때 `NEW.detail->'loaded_items'`를
`jsonb_array_elements`로 순회하며, 각 원소의 `dispatch_sequence_id`가
가리키는 `wms.dispatch_sequences` 행을 찾아 `item_outcome='LOADED'`면
`status='COMPLETED'`로, `'SKIPPED'`면 `status='FAILED'`로 갱신하고
`load_position`을 반영하며 `version`을 증가시킨다. 이 트리거는 area1의
마이그레이션이 먼저 적용된 뒤, 이 변경의 마이그레이션에서
`create trigger ... on wms.equipment_status_events`로 추가한다 — 그 테이블의
원 소유 마이그레이션 파일 자체는 수정하지 않는다.

## 역할 모델

새 역할을 추가하지 않는다. 기존 역할 재사용:

| 역할 | 이 계약에서의 권한 |
|---|---|
| `WMS_ADMIN` | 모든 쓰기 RPC 호출 가능 |
| `WAREHOUSE_MANAGER` | 출고 단위 등록, 서열 배정·취소, 팔레타이징 명령 디스패치 |
| `WCS_OPERATOR` | 서열 배정·취소, 팔레타이징 명령 디스패치(출고 단위 등록은 불가 — 출고 단위 생성은 상위 업무 판단으로 제한) |
| `PROCESS_AGENT` | 출고 단위 등록, 서열 배정·취소, 팔레타이징 명령 디스패치(ProcessGPT 자동화 경로) |
| `WCS_GATEWAY` | `PALLETIZE`/`WRAP` 결과 보고는 area1의 `wms_report_command_result` 허용 역할을 그대로 따름. 이 계약의 쓰기 RPC 호출 권한 없음 |

## RLS 패턴

기존 테이블과 동일하게, 신규 2개 테이블 모두:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer` RPC를
  통해서만 이루어진다.

`wms.equipment_commands`, `wms.equipment_status_events`, `wms.dispatch_waves`의
기존 RLS 정책은 변경하지 않는다 — 이 계약이 추가하는 트리거는 정책이 아니라
트리거 함수 안에서 동작하므로 RLS와 독립적이다.

## 확장 지점 (후속 한 영역, area6)

| 후속 영역 (가칭 spec ID) | 이 계약을 어떻게 확장하는가 |
|---|---|
| `wms_wes-digital-twin`(디지털 트윈/시뮬레이션, area6) | `WCS_GATEWAY`로 인증하는 시뮬레이터가 `wms_report_command_result`를 `PALLETIZE`/`WRAP` 결과로 호출하면, 이 계약의 검증(D5)·항목 단위 완료 전파(D6) 트리거가 그대로 반응한다 — 이 계약을 수정할 필요가 없다. 또한 시뮬레이션 환경은 "혼합 팔레타이징 계획(선언 중량/용적) vs 실측 결과(outcome)"의 편차(D7)를 재현하는 첫 실제 테스트베드가 될 수 있다. |

area4(`wms_wcs-bottleneck-routing`)와의 향후 통합 가능성(D9 참고): 현재는
`wms_dispatch_palletize_command`가 `p_equipment_id`를 필수로 받지만, "어느
로봇 셀에 새 팔레트 빌드를 시작할지" 결정 자체를 자동화하는 후속 확장이
생기면 그 결정 로직이 area4의 `wms.wcs_equipment_bottleneck_status` 뷰를
참고하도록 설계할 수 있다 — 이번 변경은 그 자동화를 하지 않는다.

## 프론트엔드 확장 지점 (구현 아님, 위치만 기록)

- `/wcs/sequential-dispatch` — 출고 단위 등록·서열 배정 현황(웨이브별,
  팔레트별)을 보여주는 화면 후보. `frontend/src/views/`에
  `SequentialDispatchView.vue` 형태로 추가될 후보.
- `/wcs/pallet-manifest` — 완성/진행 중 팔레트의 구성(어느 서열 아이템이
  어느 위치에 실렸는지)을 보여주는 화면 후보. area1의 `/wcs/monitor`와 함께
  배치될 수 있다.

이번 변경은 위 두 화면을 구현하지 않는다 — RPC/MCP 계약만 제공한다.

## Risks / Trade-offs

- **선행 변경 두 개(area1 전체, area2 일부) 모두 미구현에 대한 의존.**
  완화책: 이 변경의 실제 마이그레이션 의존성은 area1 + area2의
  `wms.dispatch_waves`뿐임을 명시하고(Context 절), E2E는 두 선행 변경의
  시뮬레이터/왕복 검증 자산을 재사용한다.
- **`wms.outbound_orders`가 main repo `wms_outbound-fulfillment`의 정식
  스펙과 이름이 겹친다.** 완화책: proposal.md와 이 문서 양쪽에 "이 테이블은
  그 목표 아키텍처의 극히 축소된 골격이며, 향후 정식 `wms_outbound-fulfillment`
  스펙이 등장하면 재사용되거나 대체될 수 있다"고 명시했다. 정식 스펙이
  나오면 이 테이블의 컬럼(할당 상태, lot/serial 등)을 대폭 확장하거나
  마이그레이션으로 교체해야 할 수 있다 — 이는 알려진 기술 부채로 남긴다.
- **area1이 예견한 확장 경로(work_order 재사용)를 따르지 않고 새 엔티티를
  만든 것(D1)은 area1 design.md의 확장 지점 표와 실제 구현이 어긋난다는
  인상을 줄 수 있다.** 완화책: 그 표가 "가칭"이며 강제 계약이 아님을
  명시했고, D1에 새 엔티티를 선택한 구체적 근거(N:1 관계 표현)를 남겼다.
- **`PALLETIZE` 명령의 대상 설비를 자동 선택하지 않는 것(D4)은 area2/area4의
  부하 분산 철학과 다른 예외를 만든다.** 완화책: 그 예외의 물리적 근거
  (하나의 팔레트는 한 셀에서 쌓여야 한다)를 D4에 명시했다 — 이는 임의의
  설계 취향이 아니라 도메인 제약에서 나온 결정이다.
- **항목 단위 완료 전파 트리거(D6)가 `jsonb_array_elements`로 배열을 순회하는
  것은 area2의 단일 행 갱신 트리거보다 복잡하고, `loaded_items` 배열이
  비정상적으로 크거나 형식이 어긋나면 트리거 자체가 실패할 위험이 있다.**
  완화책: D5의 구조 검증 트리거(`BEFORE INSERT`)가 먼저 실행되어 형식을
  보장한 뒤에만 D6의 전파 트리거(`AFTER INSERT`)가 실행되도록 트리거
  순서를 tasks.md에 명시한다.
- **`declared_weight_kg`/`declared_volume_l`을 호출자 선언값으로 둔 것은
  실제 계근 없이도 통과할 수 있다는 뜻이다.** 완화책: 이는 정직한 스코프
  축소로 이미 명시했다(Context) — 실제 계근 연동은 `wms.products` 마스터
  데이터 확장과 함께 다뤄야 할 별도 스코프다.
