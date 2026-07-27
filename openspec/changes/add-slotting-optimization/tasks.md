## 0. 선행 조건 확인

- [x] 0.1 대상 데이터베이스에 `20260726_wms_core_schema.sql`이 적용되어
      있는지 확인한다 — 이 변경의 모든 테이블/RPC는 `wms.products`,
      `wms.warehouses`, `wms.stock_ledger_entries`, `wms.memberships`,
      `wms.has_role`, `wms.current_warehouse_ids`만 존재하면 적용할 수
      있다(design.md "데이터 모델" 상단 참고).
- [x] 0.2 다른 area(`add-wcs-*`, `add-wes-*`, `add-yard-dock-scheduling`)의
      마이그레이션 적용 여부는 이 변경의 착수 조건이 아님을 확인한다 —
      이 변경은 areas 1-8 어디에도 스키마 의존이 없다(design.md, 독립
      영역). 확인 완료: 신규 마이그레이션은 `wms.tenants`, `wms.warehouses`,
      `wms.products`, `wms.stock_ledger_entries`, `wms.memberships`,
      `wms.idempotency_records`, `wms.audit_events`, `wms.has_role`,
      `wms.current_warehouse_ids`만 참조한다.

## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/20260804_slotting_optimization.sql`을 추가하고
      `wms.storage_locations`, `wms.slotting_class_policies`,
      `wms.sku_velocity_snapshots`, `wms.slotting_recommendations`,
      `wms.sku_location_assignments`를 design.md 데이터 모델대로
      생성했다(선언 순서는 `sku_location_assignments.source_recommendation_id`
      의 FK 방향 때문에 추천 테이블 뒤로 옮겼다). 기존 9개 마이그레이션은
      한 줄도 고치지 않았다.
- [x] 1.2 `unique (warehouse_id, location_code)`,
      `unique (warehouse_id, product_id)`,
      `unique (warehouse_id, velocity_class)`,
      `unique (batch_id, product_id)`를 추가하고
      `accessibility_rank > 0`, `capacity_qty >= 0`,
      `max_accessibility_rank > 0` CHECK을 추가했다.
      검증: `verify.sql` A3(제약 22건 목록), B2/B9/B12(중복 거부),
      B4(잘못된 rank/capacity 거부).
- [x] 1.3 `status`/`reason_code`/`velocity_class`/`assigned_reason` enum CHECK에
      더해 관계 불변식 4종을 추가했다 —
      `slotting_recommendations_reason_ck`(사유 코드와 현재 위치 null 여부가
      어긋날 수 없음), `_applied_ck`, `_reviewed_ck`, `_not_self_ck`.
- [x] 1.4 `wms.slotting_recommendation_overview_v`를 `security_invoker = true`로
      생성했다(추천 + 제품 + 현재/추천 위치 + 스냅샷 + 정책 조인,
      `accessibility_gain` 파생 컬럼 포함). 검증: `verify.sql` A5, F2, K2.

## 2. RLS 정책

- [x] 2.1 5개 신규 테이블에 `enable row level security`를 적용하고
      `warehouse_id in (select wms.current_warehouse_ids(tenant_id))` `select`
      정책만 추가했다. 검증: `verify.sql` A1/A2(RLS on, 정책은 SELECT 5개뿐),
      K1/K2.
- [x] 2.2 `authenticated`에 신규 테이블의 `insert`/`update`/`delete` 권한이
      없음을 psql로 점검했다. 검증: `verify.sql` K3(세 종류 전부
      `permission denied`), K4(그랜트 테이블에 `SELECT`만, 뷰 포함 6개).
- [x] 2.3 교차 테넌트 접근 차단을 직접 검증했다. 검증: `verify.sql`
      K2(테넌트 B 관리자에게 위치·배정·정책·스냅샷·추천·뷰 전부 0건),
      J1(RPC 3종 전부 `FORBIDDEN`).

## 3. Command RPC

- [x] 3.1 `wms.wms_register_storage_location` — 역할 검사, 창고 스코프,
      중복 `location_code` 거부, 초기 `ACTIVE`, 멱등성/감사 연동.
      `capacity_qty`를 넣으면 `CAPACITY_NOT_ENFORCED` 경고를 함께 반환한다.
      검증: `verify.sql` B1~B5.
      **DEVIATION V1**: design.md 시그니처는 `p_capacity_qty default null`
      뒤에 기본값 없는 `p_actor_id`/`p_idempotency_key`를 두어 PostgreSQL이
      거부한다. `p_capacity_qty`를 `p_idempotency_key` 뒤로 옮겼다(20260802/
      20260803과 같은 수정). 호출자는 전부 이름으로 넘기므로 관측되지 않는다.
- [x] 3.2 `wms.wms_set_storage_location_status` — 버전 검증,
      `ACTIVE`/`INACTIVE` 외 값 거부, 같은 상태로의 전환 거부. 비활성화해도
      기존 배정을 쫓아내지 않고 `STILL_ASSIGNED_SKUS: n` 경고로 알린다.
      검증: `verify.sql` B6, H6.
- [x] 3.3 `wms.wms_assign_sku_location` — 역할 검사(+`INBOUND_OPERATOR`),
      대상 위치 `ACTIVE` 검증, 중복 배정 거부, `MANUAL_DECLARATION` 기록.
      모든 성공 응답에 `DECLARATION_NOT_RECONCILED_WITH_PUTAWAY` 경고를
      붙인다(D1: 원장에 위치 축이 없어 대조 불가). 검증: `verify.sql`
      B7/B8/B9.
- [x] 3.4 `wms.wms_reassign_sku_location` — 버전 검증, 대상 위치 `ACTIVE`
      검증, 같은 위치로의 재배정 거부. 손으로 옮기면
      `assigned_reason='MANUAL_DECLARATION'`으로 돌아가고
      `source_recommendation_id`가 지워진다. 검증: `verify.sql` B10.
- [x] 3.5 `wms.wms_register_slotting_class_policy` /
      `wms.wms_update_slotting_class_policy` — 역할 검사, 중복
      `(warehouse_id, velocity_class)` 거부, 버전 검증. 상한을 만족하는
      ACTIVE 위치 수를 `qualifying_location_count`로 돌려주고 0이면
      `NO_QUALIFYING_LOCATION` 경고를, 갱신 시에는 `REGENERATE_TO_APPLY`
      경고를 붙인다. 검증: `verify.sql` B11/B12.
- [x] 3.6 `wms.wms_compute_sku_velocity` — 윈도우 검증,
      `status='AVAILABLE' and qty_delta < 0`만 집계, 누적 비중 80/95 컷오프,
      신호 없는 SKU는 스냅샷 미생성 + `skipped_no_data_count` 반영, 공통
      `batch_id`. 검증: `verify.sql` C3~C6(신호 없는 정직한 기본값 —
      **시드 그대로, 소비 이력 주입 없이 재현됨**), E1~E5(ABC 분류,
      경계값 80.00/95.00, 다른 상태 신호 무시, 윈도우 밖).
      **DEVIATION V2**: `skipped_no_data_count`의 모집단은 테넌트의 제품
      전체다 — `wms.products`가 테넌트 스코프이고 제품-창고 레지스트리가
      이 저장소에 없다. `candidate_product_count`를 응답에 함께 실어
      `candidate = included + skipped`를 검증 가능하게 했다.
      **DEVIATION V5**: 등급 경계는 포함(inclusive)이고, 비교를
      `cum_qty * 100 <= total_qty * 80` 정수 산술로 써서 정확히 80%인 값이
      부동소수점 오차로 경계를 놓칠 수 없게 했다.
- [x] 3.7 `wms.wms_generate_slotting_recommendations` — 배치 대조,
      `RELOCATE_UNDERSERVED` / `UNASSIGNED_HIGH_VELOCITY` 생성, 정책 없는
      등급은 `skipped_no_policy_classes`에, 이미 적정 위치는
      `skipped_already_optimal_count`에 반영. 검증: `verify.sql` F1~F5.
      **DEVIATION V3**: 대상 위치를 "상한을 만족하는 위치 중 아무거나"가
      아니라 (미배정 → 다른 추천이 노리지 않음 → 최상 순위 → 코드) 순으로
      고른다. 필터가 아니라 선호라, 전부 차 있어도 SKU를 버리지 않는다.
      **DEVIATION V4**: 열린(PENDING/APPROVED) 추천이 있는 SKU는 재생성에서
      제외하고 `skipped_open_recommendation_count`에 센다(D3의 "정책 바꿔
      가며 재생성" 워크플로에서 중복이 쌓이지 않게).
      추가 필드 `skipped_no_target_location_count`도 함께 반환한다.
- [x] 3.8 `wms.wms_review_slotting_recommendation` — `WMS_ADMIN`/
      `WAREHOUSE_MANAGER`만, `PENDING` 검증, 버전 검증, `reviewed_by`/
      `reviewed_at` 기록. 승인 시 `ASSIGNMENT_UNCHANGED_UNTIL_APPLIED` 경고.
      검증: `verify.sql` G1~G6 (PROCESS_AGENT·INBOUND_OPERATOR 모두
      `FORBIDDEN`, 재검토 `INVALID`, 잘못된 decision `INVALID`, 버전
      `CONFLICT`).
- [x] 3.9 `wms.wms_apply_slotting_recommendation` — `APPROVED` 검증, 배정
      갱신/신규 생성과 `APPLIED` 전이를 한 트랜잭션으로, `assigned_reason`/
      `source_recommendation_id` 기록, 대상 위치 `ACTIVE` 재확인. 항상
      `RECORD_ONLY_NO_PHYSICAL_MOVE_VERIFIED` 경고를 붙인다.
      검증: `verify.sql` H1~H6.
- [x] 3.10 10개 RPC 전부에 `grant execute ... to authenticated`를 추가했다
      (내부 헬퍼 `_wms_slotting_admin_guard`, `_wms_load_active_location`,
      `_wms_pick_slotting_target`은 grant하지 않는다 —
      `_wms_finalize_disposition`과 동일). 검증: `verify.sql` A4.
- [x] 3.11 감사 이벤트 커버리지를 psql로 점검했다 — 10개 command 전부
      기록되고 `actor_id` 누락 0건, 적용은 추천과 배정 **양쪽**을 감사한다
      (배정의 이전 위치가 `before`에 남는다 = D1의 이력). 검증:
      `verify.sql` I1/I2/I3.
- [x] 3.12 멱등성 재시도 테스트 — 동일 키로 `wms_register_storage_location`
      2회 호출 시 같은 `document_id`, 위치는 1건. 검증: `verify.sql` B5.

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 기존 `@mcp.tool` 패턴으로 10개 도구를 추가했다:
      `register_storage_location`, `set_storage_location_status`,
      `assign_sku_location`, `reassign_sku_location`,
      `register_slotting_class_policy`, `update_slotting_class_policy`,
      `compute_sku_velocity`, `generate_slotting_recommendations`,
      `review_slotting_recommendation`, `apply_slotting_recommendation`.
      (기존 64종 → 74종, 기존 도구는 변경 없음)
- [x] 4.2 각 도구가 RPC의 `next_actions`를 그대로 전달하고, 정직성 필드를
      `links`로 올려 준다(`skipped_no_data_count`,
      `skipped_no_policy_classes`, `assignment_created` 등).
      `generate_slotting_recommendations`의 `next_actions`는
      `["review_slotting_recommendation"]`이고, 승인 응답은
      `["apply_slotting_recommendation"]`이다 — 에이전트가 받는 다음 단계가
      곧 자기 권한 밖이라는 사실이 도구 docstring에 명시되어 있다.
- [x] 4.3 `docs/03-processgpt-integration.md` 허용 목록에
      `wms.compute_sku_velocity`, `wms.generate_slotting_recommendations`
      2종만 추가하고, 나머지 8종을 제외한 이유를 note로 남겼다(승인/적용은
      물리적 이동 결정이라 사람 전용, 위치·정책은 마스터데이터, 배정 선언은
      검증 불가능한 현장 관찰 진술). `skipped_no_data_count`를 반드시 읽으라는
      경고도 함께 적었다.

## 5. E2E 검증 (`openspec/specs/wms_slotting-optimization/e2e/`에 응집)

- [x] 5.1 시드 데이터 상태 그대로 `wms_compute_sku_velocity`를 호출해
      "소비 이력이 전혀 없는 SKU는 등급 없이 명시적으로 제외된다" 시나리오를
      **소비 이력 주입 없이** 재현했다 — `verify.sql` C3
      (`NO_SIGNAL`, `included=0`, `skipped_no_data=7`), 그리고 화면에서도
      `slotting-flow.spec.ts` 테스트 1 / 스크린샷 04.
      함께 확인한 것: 원장 전체에 `AVAILABLE` 음수 행 0건(C1), area5/6 계열
      `source_type` 원장 행 0건(C2) — design.md의 예측을 **실제 적용된
      마이그레이션에 대고** 다시 확인했다. area5의 `wms.outbound_orders`는
      구현되어 `COMPLETED`까지 도달하지만 원장을 쓰지 않는다.
- [x] 5.2 테스트 전용 합성 소비 행을 psql로 직접 주입해(향후 출고 RPC가 쓸
      행 모양의 대역 데이터, `source_type='SLOT-V-synthetic-consumption'` /
      `'SLOT-E2E-synthetic-consumption'`로 표시하고 끝에서 삭제) ABC 분류를
      검증했다 — `verify.sql` D/E, `slotting-flow.spec.ts` 테스트 1.
      수량은 누적 비중이 정확히 80.00%/95.00%에 떨어지도록 골랐다.
      두 스크립트 모두 **주입 전 상태를 먼저 검증한 뒤** 주입한다.
- [x] 5.3 위치 등록 → 정책 등록 → 배정 선언 → 속도 계산 → 추천 생성 →
      승인 → 적용 전체 왕복을 검증했고, 적용 후
      `wms.sku_location_assignments.location_id`가 추천 위치로(rank 20 → 1)
      실제로 바뀌었음을 확인했다 — `verify.sql` H2/H3,
      `slotting-flow.spec.ts` 테스트 2 / 스크린샷 08→09.
- [x] 5.4 정책 없는 등급 건너뛰기(`["B"]`), 이미 적정 위치의 SKU 미추천,
      배정 없는 SKU의 `UNASSIGNED_HIGH_VELOCITY` 추천을 각각 검증했다 —
      `verify.sql` F1/F2/F3, UI에서도 동일(스크린샷 06).
      배정 없던 SKU에 적용하면 신규 배정이 생기는 것(D5의 나머지 반쪽)은
      `verify.sql` H5(`assignment_created=true`, `version=1`).
- [x] 5.5 역할 오류(`FORBIDDEN`)와 버전 충돌(`CONFLICT`)을 psql로 직접
      확인했다 — B3(위치 등록), C5(속도 계산), G1(PROCESS_AGENT 검토·적용),
      G2(INBOUND_OPERATOR 검토), J1(교차 테넌트 3종) /
      B6·B10·G3(위치·배정·추천 버전 충돌).
- [x] 5.6 시나리오 스크립트와 실행 결과를
      `openspec/specs/wms_slotting-optimization/e2e/`에 정리했다:
      `verify.sql`, `verify-run.txt`(786줄, `supabase db reset` 직후 실행),
      `playwright-run.txt`(19/19 통과), `screenshots/`(9장), `README.md`.

## 6. 문서/카탈로그 갱신

- [x] 6.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 표의 "슬롯팅 최적화"
      행은 이미 "**스펙 완료 → `wms_slotting-optimization`**"으로 표기되어
      있다(이 변경 제안 시점에 갱신됨). 회귀 없음을 확인했다.
- [ ] 6.2 이 변경이 archive될 때
      `openspec/specs/wms_slotting-optimization/spec.md`로 동기화되는지
      확인한다(`openspec archive` 절차) — archive 시점에 수행.

## 7. 프론트엔드

> **범위 변경**: design.md/proposal.md는 화면 구현을 이번 변경에서
> 제외했으나, 실제 구현 단계에서 areas 1-8과 같은 수준(뷰 + Playwright E2E +
> DOCX 매뉴얼)으로 포함하기로 했다. 아래 항목은 그에 맞춰 갱신했다.

- [x] 7.1 `frontend/src/views/SlottingView.vue`를 추가하고
      `frontend/src/router/index.ts`에 `/slotting` 라우트를,
      `frontend/src/App.vue`의 **WMS** 내비 그룹에 `Slotting` 링크를 넣었다
      (design.md는 `/inventory/slotting`을 제안했으나, 기존 라우트가
      `/labor`·`/replenishment`처럼 평평한 단일 세그먼트를 쓰고 있어 그
      관례를 따랐다).
      다섯 패널: 보관 위치 레지스트리 / SKU 위치 배정 / 등급별 목표 접근성
      정책 / 출하 속도 계산(ABC) / 재배치 추천.
      역할 게이팅이 화면에 그대로 드러난다 — 승인·반려 버튼은
      `WMS_ADMIN`/`WAREHOUSE_MANAGER`에게만 렌더링되고, 그 외 역할에는
      "승인은 창고관리자만 할 수 있습니다"가 표시된다.
      속도 계산 결과는 `대상 SKU / 분류됨 / 신호 없어 제외`를 나란히 보여
      주고, 신호가 0이면 "등급을 매기지 않았습니다" 경고 박스가 뜨며
      Generate 버튼이 비활성화된다.
- [x] 7.2 `frontend/playwright/e2e/slotting-flow.spec.ts`(테스트 2개,
      `SLOT-E2E-*` 네임스페이스, `afterAll` 정리)를 추가했다.
      전체 스위트 **19/19 통과**(이 영역 2개 + 기존 17개 회귀 없음),
      `supabase db reset` 직후 재실행으로 재확인.
- [x] 7.3 `openspec/specs/wms_slotting-optimization/docs/build_manual.mjs`로
      DOCX 운영자 매뉴얼(`slotting-optimization-operator-manual.docx`,
      2.7MB, 스크린샷 9장)을 생성했다. 스크린샷은 전부 통과한 Playwright
      실행에서 나온 실제 프레임이다.

## 8. 후속 확장 메모 (이번 변경 범위 아님)

- [ ] 8.1 (연기) `wms.outbound_orders`(area5)가 원장에 음수 `AVAILABLE`
      행을 쓰기 시작하거나, `status='COMPLETED'` 행을
      `wms_compute_sku_velocity`의 보조 신호로 UNION하는 확장을 검토한다.
      **현재 상태 재확인 결과**: area5는 실제로 구현되어 이 데이터베이스에
      적용되어 있고 주문을 `COMPLETED`까지 진행시키지만, 어떤 경로에서도
      `wms.stock_ledger_entries`를 쓰지 않는다(그 design.md Non-Goals가
      스스로 약속한 대로). 따라서 design.md가 예측한 "속도 신호 공백"은
      오늘도 그대로이며, 이번 변경은 그 테이블에 어떤 스키마 의존도 만들지
      않았다.
- [ ] 8.2 (연기) ABC 컷오프(80/95)를 창고별 정책으로 여는 것,
      `outbound_event_count`(건수) 기준 분류를 수량 기준과 별도로 제공하는 것.
- [ ] 8.3 (연기) `wms.storage_locations`를 `wms_master-data`의 정식 위치
      계층(통로·선반·빈, 용량 규칙 엔진, 위치-품목 적합성)으로 승격하는 것.
