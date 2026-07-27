## 0. 선행 조건 확인

- [x] 0.1 `add-wcs-equipment-control-contract`(area1, capability
      `wms_wcs-equipment-control`)의 마이그레이션이 대상 데이터베이스에 이미
      적용되어 있는지 확인한다. 적용되어 있지 않다면 그 변경의 tasks.md를
      먼저 완료한다 — 이 변경의 모든 DB 작업은 `wms.equipment`,
      `wms.equipment_commands`, `wms.equipment_status_events`,
      `wms_dispatch_equipment_command`, `wms_report_command_result`가
      존재함을 전제로 한다(design.md "정직한 전제 확인" 참고).
      → **확인됨. proposal/design의 "area1~4 전부 미구현"이라는 전제는 이제
      낡았다** — `supabase/migrations/20260727_wcs_equipment_control.sql`가
      실제로 적용되어 있고, 이 다섯 테이블/RPC가 전부 존재한다.
- [x] 0.2 `add-wes-material-flow-control`(area2, capability
      `wms_wes-material-flow-control`)의 마이그레이션 중 최소한
      `wms.dispatch_waves` 테이블이 적용되어 있는지 확인한다. 이 변경은
      `wms.work_orders`에는 의존하지 않는다(design.md D1) — 그 테이블 부재를
      막을 필요는 없다.
      → 확인됨(`20260728_wes_material_flow_control.sql`). `wms.dispatch_waves`
      만 참조하고 `wms.work_orders`는 참조하지 않는다는 D1을 그대로 지켰다.
- [x] 0.3 `wms.equipment_commands.command_type` `CHECK` 제약의 실제 이름을
      `information_schema.table_constraints`로 확인한다. `add-wcs-sortation-logic`
      (area3)이 이미 이 제약을 한 번 교체했을 수 있으므로, 이 변경의
      마이그레이션(1.2)은 area3 적용 여부와 무관하게 동작하도록 현재 값
      집합을 조회한 뒤 `PALLETIZE`, `WRAP`을 추가해 반영한다.
      → 제약명 `equipment_commands_command_type_check`, 현재 값 집합은
      area3가 남긴 `MOVE…RESUME + DIVERT, SET_SPEED`. **그리고 area3가 경고한
      함정이 그대로 재발했다 — `wms_dispatch_equipment_command`도 같은 목록을
      함수 본문에 하드코딩한다.** 1.2 참고.

## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/`에 새 마이그레이션 파일(예:
      `<timestamp>_wms_wcs_sequential_dispatch.sql`)을 추가하고
      `wms.outbound_orders`, `wms.dispatch_sequences` 테이블을 design.md
      데이터 모델대로 생성한다. 파일 이름의 타임스탬프는 area1과 area2
      (`wms.dispatch_waves`)의 마이그레이션보다 뒤여야 한다. "출고 단위
      등록", "디스패치 웨이브 내 서열 배정" Requirement 검증.
      → `supabase/migrations/20260731_wcs_sequential_dispatch.sql`.
- [x] 1.2 `wms.equipment_commands.command_type` `CHECK` 제약을 교체해
      `PALLETIZE`, `WRAP` 값을 추가한다(design.md, 0.3에서 확인한 현재
      값 집합 기준). 원 테이블 정의(area1의 마이그레이션)는 수정하지 않는다.
      → **DEVIATION 1**: 제약만 완화하는 것은 no-op이다.
      `wms_dispatch_equipment_command`가 자기 본문에도 command_type 목록을
      하드코딩하고 있어 완화된 제약에 닿기 전에 `INVALID:`로 거부한다.
      area3와 똑같이 `create or replace`로 그 한 줄만 확장했다. **베이스는
      area1의 원본이 아니라 area3(20260729)의 교체본** — area4는 이 함수를
      건드리지 않고 `_wms_pick_equipment_for_work_order`를 교체했기 때문이다.
- [x] 1.3 `wms.equipment_commands`에 `BEFORE INSERT` 트리거(또는 area3가
      이미 추가한 트리거에 조건 분기 추가 — 실제로는 트리거 이름 충돌을
      피하기 위해 별도 트리거로 추가)를 만든다(design.md D4) —
      `ROBOT_CELL`이 아닌 설비에 `PALLETIZE`/`WRAP` 명령 거부, `PALLETIZE`
      payload의 `target_pallet_code`/`sequence_items`(비어있지 않음,
      `sequence_position` 오름차순) 필수 검증, `max_weight_kg`/`max_volume_l`
      지정 시 대상 서열 배정들의 선언값 합계 초과 여부 검증(design.md D7),
      `WRAP` payload의 `pallet_code`/`wrap_program` 필수 검증. "혼합
      팔레타이징 명령 디스패치", "스트레치 포장 명령 payload 계약"
      Requirement의 시나리오 전부 검증.
      → `_wms_validate_palletize_command` + 트리거
      `equipment_commands_validate_palletize`(area3의 트리거와 이름·대상
      command_type이 겹치지 않음). 중량/용적 상한 검증을 RPC가 아니라 이
      트리거에 둔 이유: 범용 `wms_dispatch_equipment_command`로 직접 보내는
      경로에도 같은 규칙이 걸리게 하기 위함(3.9와 같은 검증).
- [x] 1.4 `wms.equipment_status_events`에 `BEFORE INSERT` 트리거를 추가한다
      (design.md D5) — `event_type in ('COMMAND_COMPLETED','COMMAND_FAILED')`이고
      연결된 명령이 `command_type='PALLETIZE'`일 때 `detail.outcome`과
      명령 상태의 정합성(`SUCCESS`/`PARTIAL`↔`COMPLETED`,
      `OVERWEIGHT`/`OVERVOLUME`/`ABORTED`↔`FAILED`)을 검증해 어긋나면
      `INVALID:`를 발생시킨다. `WRAP` 결과의 `outcome`/명령 상태 정합성도
      함께 검증한다. "팔레타이징 결과 보고와 항목 단위 상태 반영" Requirement의
      정합성 관련 시나리오 검증.
      → `_wms_validate_palletize_outcome` + 트리거
      `equipment_status_events_validate_palletize_outcome`. 항목 배열까지
      검증한다(`item_outcome` 값 집합, outcome별 허용 조합, 그 명령에 속한
      배정인지, `LOADED`면 `load_position` 필수).
- [x] 1.5 `wms.equipment_status_events`에 `AFTER INSERT` 트리거를 추가한다
      (design.md D6) — `PALLETIZE` 결과의 `detail.loaded_items` 배열을
      `jsonb_array_elements`로 순회하며 각 `dispatch_sequence_id`가 가리키는
      `wms.dispatch_sequences` 행의 `status`(`item_outcome='LOADED'`→`COMPLETED`,
      `'SKIPPED'`→`FAILED`)와 `load_position`을 갱신한다. 1.4의 검증
      트리거가 먼저 실행된 뒤(같은 `BEFORE`/`AFTER` 시점 분리)에만 이
      트리거가 실행되도록 순서를 확인한다. "팔레타이징 결과 보고와 항목
      단위 상태 반영" Requirement의 반영 관련 시나리오 전부 검증.
      → `_wms_propagate_palletize_result` + 트리거
      `equipment_status_events_propagate_palletize`. 순서는 이름이 아니라
      **타이밍**이 보장한다(1.4는 BEFORE, 이것은 AFTER). 출고 단위 상태도
      함께 따라간다.
- [x] 1.6 `wms.outbound_orders.status`, `wms.dispatch_sequences.status`에
      `CHECK` 제약을 추가해 스펙에 정의된 값 집합만 허용되게 하고,
      `unique (outbound_order_id)`(서열 배정), `unique (wave_id,
      sequence_position)` 제약을 추가한다.
      → **DEVIATION 3**: 두 유일성 제약은 `status <> 'CANCELLED'` 조건이 붙은
      **부분 유니크 인덱스**로 구현했다. 평범한 UNIQUE로 두면 취소된 배정이
      출고 단위와 서열 자리를 영구히 점유해 "서열 배정 취소" Requirement가
      존재하는 이유(취소 후 재배정)를 스스로 막는다. design.md도
      "출고 단위당 **활성** 서열 배정 1건만"이라고 썼다.

## 2. RLS 정책

- [x] 2.1 `wms.outbound_orders`, `wms.dispatch_sequences`에 `enable row
      level security`를 적용하고, 기존 테이블과 동일한 패턴(`warehouse_id
      in (select wms.current_warehouse_ids(tenant_id))`)의 `select` 정책만
      추가한다. "테넌트·창고 단위 접근 통제" Requirement 검증.
- [x] 2.2 `authenticated`/`anon`에 두 테이블의 `insert`/`update`/`delete`
      권한을 부여하지 않았는지 확인하는 psql 점검 스크립트를 작성한다.
      → `simulator.sql` §12 — `information_schema.role_table_grants`에
      `authenticated: SELECT` 두 줄만, `anon`은 0줄. 직접
      INSERT/UPDATE/DELETE는 `permission denied`.
- [x] 2.3 교차 테넌트 접근 차단을 psql로 직접 검증한다(테넌트 A 사용자가
      테넌트 B 출고 단위에 서열을 배정할 수 없음). "다른 테넌트의 출고
      단위에는 접근할 수 없다" 시나리오 검증.
      → `simulator.sql` §3(테넌트 B 관리자 → `FORBIDDEN`), §11(테넌트 B가
      보는 행 수 0).

## 3. Command RPC

- [x] 3.1 `wms.wms_create_outbound_order`를 구현한다 — 역할 검사
      (`WAREHOUSE_MANAGER`, `PROCESS_AGENT`, `WMS_ADMIN`), 창고 스코프 검사,
      `qty > 0` 검증, `wms.idempotency_records` 연동, `wms.audit_events`
      기록. "출고 단위 등록" Requirement의 3개 시나리오 전부 검증.
- [x] 3.2 `wms.wms_assign_dispatch_sequence`를 구현한다 — 대상 웨이브
      `status='OPEN'` 검증(area2 패턴 재사용), `sequence_position` 유일성
      검증, `expected_version` 기반 낙관적 동시성, 출고 단위 상태를
      `SEQUENCED`로 전이. "디스패치 웨이브 내 서열 배정" Requirement의
      4개 시나리오 전부 검증.
- [x] 3.3 `wms.wms_cancel_dispatch_sequence`를 구현한다 — `QUEUED`/`DISPATCHED`만
      취소 허용, `DISPATCHED`면 연결된 설비 명령도
      `wms_cancel_equipment_command`(area1)로 취소 시도. "서열 배정 취소"
      Requirement의 3개 시나리오 전부 검증.
      → **DEVIATION 4**: `PALLETIZE`는 N:1이므로 명령을 취소하면 같은 명령에
      실려 있던 **형제 배정도 함께 CANCELLED**로 내린다(그대로 두면
      "CANCELLED 명령을 타고 있는 DISPATCHED 배정"이라는 거짓 상태가 남는다).
      `cancelled_sibling_sequence_ids`와 `SIBLING_SEQUENCES_CANCELLED` 경고로
      알린다. 취소된 출고 단위는 `OPEN`으로 되돌린다(1.6과 짝).
- [x] 3.4 `wms.wms_dispatch_palletize_command`를 구현한다 — 대상
      `(wave_id, target_pallet_code)`로 `QUEUED` 서열 배정 조회 및
      `sequence_position` 순 정렬, `payload.sequence_items` 구성,
      `max_weight_kg`/`max_volume_l` 사전 검증, 내부적으로 area1의
      `wms_dispatch_equipment_command` 호출, 성공 시 대상 서열 배정 전부를
      `DISPATCHED`로 일괄 전이하고 `equipment_command_id` 채움. "혼합
      팔레타이징 명령 디스패치" Requirement의 4개 시나리오 전부 검증.
      → **DEVIATION 2**: design.md의 역할 목록과 달리 `WMS_ADMIN`을 제외하고
      `wms_dispatch_equipment_command`가 실제 허용하는 집합
      (`WAREHOUSE_MANAGER`/`WCS_OPERATOR`/`PROCESS_AGENT`)을 그대로 쓴다.
      넣었다면 배치를 다 읽고 payload까지 만든 뒤 내부 호출에서만
      `FORBIDDEN`이 되는 부분 실패가 생긴다(area2가 겪은 것과 같은 함정).
      D4의 설비 가용성 규칙(IDLE, 또는 **같은** 팔레트를 쌓는 중인 RUNNING)도
      함께 구현했다.
- [x] 3.5 `wms.wms_get_dispatch_sequence_status`,
      `wms.wms_get_pallet_manifest`를 구현한다 — 읽기 전용 조인 조회.
      "서열/팔레트 현황 조회", "팔레트 매니페스트 조회" Requirement의
      시나리오 전부 검증.
      → 전자는 화면 한 번에 필요한 다섯 묶음(`outbound_orders`, `sequences`,
      `waves`, `robot_cells`, `pallets` 롤업)을 함께 돌려준다. 후자는 결과가
      아직 없으면 오류가 아니라 `reported=false`, `items=[]`, 계획 건수만
      채운 빈 매니페스트를 돌려준다.
- [x] 3.6 4개 쓰기 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다. → 읽기 2종 포함 6종 전부.
- [x] 3.7 감사 이벤트 커버리지를 psql로 점검한다 — 출고 단위 등록, 서열
      배정, 서열 배정 취소, 팔레타이징 결과의 항목 단위 자동 반영 각각에
      대해 `wms.audit_events`에 올바른 `command`/`entity_type`/`before`/`after`가
      기록되는지 확인. "감사 추적" Requirement의 2개 시나리오 검증.
      → `simulator.sql` §13 — 5개 command × `outbound_order`/`dispatch_sequence`
      조합과, 자동 반영 행의 `DISPATCHED->COMPLETED` / `DISPATCHED->FAILED`
      before/after까지 출력한다.
- [x] 3.8 멱등성 재시도 테스트: 동일 `idempotency_key`로
      `wms_create_outbound_order`를 2회 호출해 레코드가 1건만 생성되는지
      확인한다. → `simulator.sql` §2.
- [x] 3.9 `wms_dispatch_equipment_command`(area1 소유)를 수정 없이 그대로
      호출해 1.3의 트리거가 실제로 반응하는지 통합 검증한다 — `PALLETIZE`/
      `WRAP` payload 검증 실패 케이스가 `wms_dispatch_equipment_command`의
      `INVALID:` 오류 경로로 그대로 노출되는지 확인한다.
      → `simulator.sql` §5(7개 케이스, 그 결과 명령 행 0건). 단 "수정 없이"는
      불가능했다 — 1.2 DEVIATION 1 참고(command_type 목록이 함수 본문에도
      있어 `create or replace`가 필요했다). 그 외의 payload 검증은 전부
      트리거가 담당하므로 함수 본문은 그 한 줄 외에 바뀌지 않았다.

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 기존 `@mcp.tool` 패턴을 따라 아래 도구를 추가한다:
      `create_outbound_order`, `assign_dispatch_sequence`,
      `cancel_dispatch_sequence`, `dispatch_palletize_command`,
      `get_dispatch_sequence_status`, `get_pallet_manifest`. `WRAP` 디스패치나
      `PALLETIZE`/`WRAP` 결과 보고를 위한 새 도구는 추가하지 않는다 — 기존
      `dispatch_equipment_command`/`report_command_result` 도구를 그대로
      사용한다는 점을 문서 주석으로 남긴다.
      → 6종 추가(총 32 → 38종). 섹션 헤더 주석과
      `dispatch_palletize_command` docstring에 `WRAP` payload·결과 보고
      `detail` 형식을 명시했고, 기존 `dispatch_equipment_command`의
      `command_type` 설명·docstring에도 `PALLETIZE`/`WRAP`을 추가했다.
- [x] 4.2 각 쓰기 도구 반환값에 `next_actions`를 채운다(예:
      `create_outbound_order` → `["assign_dispatch_sequence"]`,
      `assign_dispatch_sequence` → `["dispatch_palletize_command"]`).
- [x] 4.3 `docs/03-processgpt-integration.md`의 에이전트 tool 허용 목록
      표에 이 스펙에서 `PROCESS_AGENT`가 실제로 호출 가능한 도구 목록을
      추가한다(design.md 역할 모델 참고 — `PROCESS_AGENT`는 4개 쓰기 도구
      전부 호출 가능).
      → 6종 전부 허용 목록에 추가하고, 두 개의 비대칭(생성은
      `WCS_OPERATOR` 불가 / 디스패치는 `WMS_ADMIN` 불가)과 항목 단위 전파,
      D7의 두 시점 검증을 note로 설명했다.

## 5. E2E 검증 (`openspec/specs/wms_wcs-sequential-dispatch/e2e/`에 응집)

- [x] 5.1 area1의 소프트웨어 시뮬레이터 스크립트를 재사용해 "출고 단위
      2건 등록 → 같은 웨이브·팔레트로 서열 배정 → PALLETIZE 명령 디스패치 →
      시뮬레이터가 outcome=SUCCESS로 COMPLETED 보고 → 두 서열 배정 모두
      COMPLETED 반영" happy path를 psql/Python으로 왕복 검증한다.
      → `e2e/simulator.sql` §0~§6, `e2e/mcp_roundtrip.py`.
- [x] 5.2 부분 적재(PARTIAL) 시나리오를 검증한다: 두 항목 중 하나만
      `LOADED`, 하나는 `SKIPPED`로 보고해 각각 다른 상태로 반영되는지
      확인한다. "팔레타이징 결과 보고와 항목 단위 상태 반영" Requirement
      검증. → `simulator.sql` §8, MCP 라운드트립 §5~6, 브라우저 스펙 §8.
- [x] 5.3 중량 상한 사전 검증(디스패치 거부)과 사후 결과(OVERWEIGHT 보고)
      두 경로를 모두 재현해 design.md D7이 설명하는 "계획 단계 실수"와
      "실측 단계 편차"의 차이가 실제로 관찰 가능한지 확인한다.
      → `simulator.sql` §4(사전, 중량·용적 둘 다)와 §8(사후). §8 끝에서 두
      실패를 나란히 출력한다.
- [x] 5.4 서열 배정 취소가 연결된 설비 명령 취소까지 전파되는지, 웨이브가
      이미 `RELEASED`일 때 서열 배정이 거부되는지 확인한다.
      → `simulator.sql` §10(형제 배정까지 — DEVIATION 4)과 §3(RELEASED 웨이브).
- [x] 5.5 `WRAP` 명령 디스패치와 결과 보고가 서열 배정 상태에 영향을 주지
      않는지(design.md D8) 확인한다. → `simulator.sql` §9 — 전후 COMPLETED
      건수가 같음을 출력. MCP 라운드트립·브라우저 스펙도 같은 불변식을 검사.
- [x] 5.6 교차 테넌트/역할 오류 케이스(`FORBIDDEN`)와 버전 충돌 케이스
      (`CONFLICT`)를 psql로 직접 호출해 확인한다.
      → `simulator.sql` §1(역할 2종), §3(교차 테넌트, stale version), §4
      (`WMS_ADMIN`·`QUALITY_INSPECTOR` 디스패치 거부, stale equipment
      version), §7·§11(다른 창고 조회), §10(stale sequence version).
- [x] 5.7 시뮬레이터 스크립트, 실행 결과를
      `openspec/specs/wms_wcs-sequential-dispatch/e2e/` 아래에 정리한다.
      → `simulator.sql` / `simulator-run.txt` / `mcp_roundtrip.py` /
      `mcp_roundtrip-run.txt` / `playwright-run.txt` / `screenshots/`(18장) /
      `README.md`(커버리지 + DEVIATION 4건 + 구현 중 발견해 고친 버그 2건).

## 6. 문서/카탈로그 갱신

- [x] 6.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "서열
      출고/지능형 적재" 행에 "스펙 완료 → `wms_wcs-sequential-dispatch`"
      비고를 추가한다(이미 이 변경과 함께 완료됨 — 회귀 확인용 항목).
      → 회귀 확인 완료. 행이 그대로 있고 다른 4개 WCS/WES 행과 표기가
      일관된다.
- [ ] 6.2 이 변경이 archive될 때
      `openspec/specs/wms_wcs-sequential-dispatch/spec.md`로 동기화되는지
      확인한다(`openspec archive` 절차).
      → 미수행(archive 시점 작업). 현재 `openspec/specs/wms_wcs-sequential-dispatch/`
      에는 앞선 네 영역과 동일하게 `docs/`와 `e2e/`만 있다.
- [x] 6.3 design.md Non-Goals에 남긴 제외 범위(재고 할당/예약, Wave 기반
      피킹, 포장·출하 확정, 출고 취소·복원)가 향후 정식
      `wms_outbound-fulfillment` 스펙 후보 목록에 남아 있는지 §5 표와
      다시 대조한다.
      → 대조 완료. §5 "이미 스펙/구현이 있는 영역" 표의 `출고 및 피킹 →
      wms_outbound-fulfillment`(main repo) 행이 그대로 남아 있고, 이 변경의
      §5 행 비고에도 "재고 할당/예약·피킹·포장출하확정·출고취소(정식
      `wms_outbound-fulfillment` 몫)…는 다루지 않는다"가 명시돼 있다.

## 7. 프론트엔드 (원 계획에서는 범위 밖이었으나 이번에 함께 구현)

- [x] 7.1 (원문: 연기) `frontend/src/router/index.ts`에 `/wcs/sequential-dispatch`
      라우트와 대응 뷰 컴포넌트를 추가한다.
      → **구현함.** design.md "프론트엔드 확장 지점"이 제안한 두 화면
      (`/wcs/sequential-dispatch`, `/wcs/pallet-manifest`)을 **하나로 합쳤다** —
      매니페스트는 별도 화면으로 두기에는 맥락(어느 팔레트의, 어느 명령의)이
      항상 서열 화면 쪽에 있어서, 같은 화면 하단 섹션으로 두는 편이 왕복
      이동을 없앤다. `frontend/src/views/WcsSequentialDispatchView.vue`,
      `src/router/index.ts`, `src/App.vue` 내비게이션("WCS Sequencing").
      역할별로 카드 3종(출고 단위 등록 / 서열 배정 / 명령)이 각각 나타나고,
      `WMS_ADMIN`에게는 명령 카드 대신 안내 띠가 보인다(DEVIATION 2를 숨기지
      않는다).
- [x] 7.2 Playwright E2E 스펙 추가.
      → `frontend/playwright/e2e/wcs-sequential-dispatch-flow.spec.ts`
      (2 테스트, `SEQ-E2E-*` / `ZONE-SEQ-E2E` 네임스페이스 + `afterAll` 정리).
      전체 스위트 **11/11 통과**(기존 9 + 신규 2), 회귀 없음.
      실행 로그는 `e2e/playwright-run.txt`.
- [x] 7.3 DOCX 사용자 매뉴얼 생성.
      → `openspec/specs/wms_wcs-sequential-dispatch/docs/build_manual.mjs` →
      `wcs-sequential-dispatch-operator-manual.docx`(4.6MB, 18장 실촬 화면).
      앞선 네 매뉴얼과 동일한 생성기 형태.
