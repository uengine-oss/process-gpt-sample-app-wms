## 0. 선행 조건 확인

- [x] 0.1 `add-wcs-equipment-control-contract`(capability `wms_wcs-equipment-control`)의
      마이그레이션이 대상 데이터베이스에 이미 적용되어 있는지 확인한다. 적용되어
      있지 않다면 그 변경의 tasks.md 1~4장을 먼저 완료한다 — 이 변경의 모든
      DB 작업은 `wms.equipment`, `wms.equipment_commands`가 존재함을 전제로
      한다(design.md "정직한 전제 확인" 참고).
      → **해소됨**: proposal/design.md 작성 시점의 "선행 변경 미구현" 전제는 더
      이상 사실이 아니다. `supabase/migrations/20260727_wcs_equipment_control.sql`이
      실제로 존재하고 적용된다. 이 변경은 그 파일의 **실제** 시그니처
      (`wms_dispatch_equipment_command(equipment_id, command_type, payload,
      actor_id, idempotency_key, expected_version, correlation_id,
      linked_entity_type, linked_entity_id)`,
      `wms_cancel_equipment_command(command_id, actor_id, idempotency_key,
      expected_version, reason, correlation_id)`)를 기준으로 구현했다 —
      design.md 초안의 가상 시그니처가 아니다.

## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/20260728_wes_material_flow_control.sql`에
      `wms.dispatch_waves`, `wms.work_orders`를 design.md 데이터 모델대로
      생성했다. 타임스탬프는 area 1(`20260727_…`)보다 뒤이며,
      `supabase db reset`으로 3개 마이그레이션이 순서대로 깨끗이 적용되는 것을
      확인했다. 데이터 모델에서 추가한 것: `wms.work_orders.reason`(취소/실패
      사유), `work_orders_wave_mode_ck`(WAVE ⟺ wave_id not null), 4개 인덱스.
- [x] 1.2 `dispatch_mode`, `status`(업무 오더/웨이브 각각), `work_order_type`,
      `linked_entity_type`, 그리고 추가로 `equipment_type`/`command_type`
      (area 1의 값 집합 재사용)에 `CHECK` 제약을 추가했다.
- [x] 1.3 `wms.equipment_commands`에 `after update of status ... when (new.status
      in ('COMPLETED','FAILED') and old.status is distinct from new.status and
      new.linked_entity_type = 'work_order')` 트리거
      (`equipment_commands_propagate_work_order`)를 이 마이그레이션 파일에서만
      추가했다 — area 1의 마이그레이션 파일은 수정하지 않았다. 트리거 함수는
      `SECURITY DEFINER`라 게이트웨이 피드백 경로와 장애 일괄 실패 경로 양쪽에서
      동일하게 동작한다. "설비 명령 결과의 업무 오더 반영" 3개 시나리오
      (COMPLETED 반영 / FAILED 반영 / work_order가 아닌 참조는 무시) 모두
      `simulator.sql` §1·§6에서 검증.

## 2. RLS 정책

- [x] 2.1 두 신규 테이블에 `enable row level security` + `select` 정책
      (`warehouse_id in (select wms.current_warehouse_ids(tenant_id))`)만
      추가했다.
- [x] 2.2 `simulator.sql` §9가 `information_schema.role_table_grants`로 두
      테이블의 `authenticated`/`anon` 권한이 `SELECT` 뿐임을 출력하고, 직접
      `INSERT`/`UPDATE`/`DELETE`가 "permission denied"로 거부되는 것을 확인한다.
- [x] 2.3 `simulator.sql` §7이 테넌트 B 사용자로 두 테이블 조회 결과가 0행이고,
      테넌트 A 업무 오더 취소·조회가 `FORBIDDEN:`으로 거부되는 것을 검증한다.

## 3. Command RPC

- [x] 3.1 `wms.wms_open_dispatch_wave` 구현 — 역할 검사, 창고 스코프 검사,
      `wms.idempotency_records` 연동, `wms.audit_events` 기록.
- [x] 3.2 `wms.wms_create_work_order` 구현 — `WAVE`일 때 `wave_id`가 같은 창고의
      `OPEN` 웨이브인지 검증, `WAVELESS`일 때 같은 트랜잭션에서 3.5 호출.
      추가로 `linked_entity_id`가 같은 창고의 실제 `wms.receipts` 행인지도
      검증한다(스펙에는 없지만 존재하지 않는 엔티티를 가리키는 업무 오더를
      막는다). "업무 오더 등록" 4개 시나리오 전부 검증.
- [x] 3.3 `wms.wms_release_dispatch_wave` 구현 — 버전 검증, `RELEASED` 전이,
      `QUEUED` 업무 오더를 `created_at` 순으로 순차 디스패치, 건별 결과와
      `dispatched_count`/`queued_count`/경고 반환. 3개 시나리오 전부 검증.
- [x] 3.4 `wms.wms_retry_work_order_dispatch` 구현 — `QUEUED`가 아니면 거부,
      버전 검증, 추가로 아직 `OPEN`인 웨이브 소속 업무 오더도 거부(그건 릴리즈로
      처리해야 함). 2개 시나리오 전부 검증.
- [x] 3.5 `wms._wms_pick_equipment_for_work_order` + `wms._wms_try_dispatch_work_order`
      구현 — 타입/구역 일치(업무 오더 `zone_code`가 null이면 창고 내 전 구역),
      `status='IDLE'`, 미종결 명령 없음으로 후보를 좁히고, 최근 1시간
      `COMPLETED` 수 오름차순 → `created_at` → `equipment_code`로 정렬해 1대를
      고른다. 후보가 있으면 같은 `auth.uid()`로 `wms_dispatch_equipment_command`를
      호출하고 업무 오더를 `DISPATCHED`로, 없으면 `QUEUED` 유지 +
      `NO_EQUIPMENT_AVAILABLE` 경고. 4개 시나리오 전부 검증.
- [x] 3.6 `wms.wms_cancel_work_order` 구현 — 종결 상태 거부, `DISPATCHED`면
      연결된 명령에 `wms_cancel_equipment_command`를 같은 `auth.uid()`로 호출,
      버전 검증. 이미 종결된 명령이 연결돼 있으면 오류 대신
      `LINKED_COMMAND_ALREADY_TERMINAL` 경고. 3개 시나리오 전부 검증.
- [x] 3.7 `wms.wms_get_work_order_status` 구현 — 업무 오더 + 소속 웨이브 상태 +
      연결된 설비 명령/설비 상태를 조인해 반환하고, 창고의 웨이브 목록
      (`work_order_count`/`queued_count` 포함)도 함께 반환한다.
- [x] 3.8 6개 RPC 전부 `grant execute ... to authenticated`.
- [x] 3.9 D3 역할 일치 검증 — **불일치를 실제로 발견했고, 문서화된 이탈로
      처리했다.** 실제 `wms_dispatch_equipment_command`의 허용 역할은
      `WAREHOUSE_MANAGER`/`WCS_OPERATOR`/`PROCESS_AGENT`이고 `WMS_ADMIN`이
      **빠져 있다**(area 1 마이그레이션의 다른 모든 RPC와 다른 점). design.md/
      spec.md의 역할 표는 `WMS_ADMIN`을 포함하지만, 그대로 따르면 D3가 막으려던
      "등록은 성공, 내부 디스패치만 FORBIDDEN" 부분 실패가 그대로 재현된다.
      그래서 이 계약의 6개 쓰기 RPC는 디스패치 가능 집합에 정확히 맞췄고
      `WMS_ADMIN`을 제외했다. `simulator.sql` §7이 `admin-a@demo.local`로
      두 호출이 모두 `FORBIDDEN`임을 재현하고 두 계약의 역할 목록을
      `pg_get_functiondef`에서 추출해 나란히 출력한다. 근거와 후속 조치는
      마이그레이션 헤더와 `openspec/specs/wms_wes-material-flow-control/e2e/README.md`에
      기록했다.
- [x] 3.10 감사 이벤트 커버리지 psql 점검 — `simulator.sql` §10이 6개 쓰기 RPC
      (`wms_open_dispatch_wave`, `wms_create_work_order`,
      `wms_release_dispatch_wave`, `wms_retry_work_order_dispatch`,
      `wms_cancel_work_order`)와 내부 디스패치(`wms_dispatch_work_order`),
      완료 전파(`wms_propagate_command_result`)의 `command`/`entity_type` 건수를
      출력하고, §1이 전파 이벤트의 `before.status='DISPATCHED'` /
      `after.status='COMPLETED'` / `correlation_id`를 확인한다.
      Playwright 2번 테스트도 같은 커버리지를 브라우저 플로우 기준으로 재확인한다.
- [x] 3.11 멱등성 재시도 테스트 — `simulator.sql` §8이 동일 `idempotency_key`로
      `wms_create_work_order`와 `wms_open_dispatch_wave`를 2회 호출해 응답이
      동일하고 행이 1건만 생기는 것을 확인한다.

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 기존 `@mcp.tool` 패턴대로 6개 도구 추가:
      `open_dispatch_wave`, `create_work_order`, `release_dispatch_wave`,
      `retry_work_order_dispatch`, `cancel_work_order`, `get_work_order_status`.
      전부 `_call_rpc`(PROCESS_AGENT 신원)를 쓴다 — 이 계약에는 게이트웨이 전용
      RPC가 없다(design.md D4).
- [x] 4.2 각 쓰기 도구가 `next_actions`를 채운다 — `create_work_order`(WAVE) →
      `["release_dispatch_wave"]`, 디스패치 성공 →
      `["get_work_order_status", "cancel_work_order"]`, 설비 부족 →
      `["retry_work_order_dispatch"]`, `release_dispatch_wave`(잔여 있음) →
      `["retry_work_order_dispatch", "get_work_order_status"]`.
      `mcp_roundtrip.py`가 이 값들을 실제로 단언한다.
- [x] 4.3 `docs/03-processgpt-integration.md`의 에이전트 tool 허용 목록에 6개
      전부를 추가하고, "설비 쪽 전용 RPC가 없어 6개 모두 `PROCESS_AGENT` 허용"
      및 D3 역할 이탈을 note로 남겼다.

## 5. E2E 검증 (`openspec/specs/wms_wes-material-flow-control/e2e/`에 응집)

- [x] 5.1 happy path 왕복 검증 — `simulator.sql` §1: WAVELESS 업무 오더 등록 →
      내부 디스패치 → 게이트웨이가 ACK/IN_PROGRESS/COMPLETED 보고 → 업무 오더
      `COMPLETED` 자동 반영 + 참조 receipt는 `EXPECTED` 그대로.
      `mcp_roundtrip.py`와 Playwright 스펙도 같은 왕복을 각각 MCP 계층과 UI에서
      재확인한다.
- [x] 5.2 Wave 경로 — `simulator.sql` §4: 웨이브 개설 → 업무 오더 3건 큐잉 →
      릴리즈 → 2건 `DISPATCHED`, 1건 `QUEUED` + 경고. 재릴리즈/버전 충돌/
      RELEASED 웨이브 편입/미지의 웨이브/`wave_id` 누락 모두 거부 확인.
- [x] 5.3 흐름 균형 — `simulator.sql` §2: 최근 완료 건수가 적은 쪽(AGV-08) 선택,
      미종결 명령이 있는 설비 제외, 다른 구역(ZONE-Z) 설비 제외, 해당 타입 설비
      부재 시 `QUEUED` + 경고.
- [x] 5.4 취소 캐스케이드 — `simulator.sql` §5: `DISPATCHED` 업무 오더 취소 시
      연결된 명령이 `CANCELLED`로 바뀌고 설비가 `IDLE`로 복귀. Playwright
      7단계에서도 UI로 재확인.
- [x] 5.5 교차 테넌트/역할 `FORBIDDEN`과 버전 `CONFLICT` — `simulator.sql`
      §3·§4·§5·§7. 총 18개의 부정 경로가 `ERR ...` 로 기록된다.
- [x] 5.6 시뮬레이터 스크립트와 실행 결과를
      `openspec/specs/wms_wes-material-flow-control/e2e/`에 정리했다
      (`simulator.sql`, `simulator-run.txt`, `mcp_roundtrip.py`,
      `mcp_roundtrip-run.txt`, `playwright-run.txt`, `screenshots/` 9장,
      `README.md`).

## 6. 문서/카탈로그 갱신

- [x] 6.1 `docs/04-wms-wcs-market-feature-catalog.md` §5의 "WES/MFS 자재 흐름
      제어" 행은 이미 "스펙 완료 → `wms_wes-material-flow-control`"로 갱신되어
      있다(회귀 확인만 수행, 재편집 없음).
- [ ] 6.2 이 변경이 archive될 때 `openspec/specs/wms_wes-material-flow-control/spec.md`로
      동기화되는지 확인한다(`openspec archive` 절차).
      → **미수행**: archive는 이 구현 작업의 범위 밖이라 실행하지 않았다.
      `openspec/specs/wms_wes-material-flow-control/`에는 지금 `e2e/`와 `docs/`만
      있고 `spec.md`는 archive 시점에 생성된다.
- [x] 6.3 "미해결 통합 지점"(업무 오더 `COMPLETED` → `wms_create_putaway_tasks`
      호출 연결)을 `e2e/README.md` 마지막 절에 명시적으로 남겼다. 이 변경은 그
      연결을 만들지 않으며, simulator와 Playwright 양쪽이 "receipt는 그대로
      `EXPECTED`"임을 단언해 공백을 숨기지 않고 검증한다.

## 7. 프론트엔드

- [x] 7.1 **범위 확대(원 계획은 "연기")**: 이 변경의 계약이 실제로 사람 손에서
      동작하는지 확인하기 위해 최소 화면을 구현했다.
      `frontend/src/views/WesDispatchView.vue`(`/wes/dispatch`, 라우터 +
      사이드내비 등록) 한 화면에 웨이브 개설·릴리즈, 업무 오더 등록(WAVE/
      WAVELESS), 재시도, 취소, 그리고 연결된 설비 명령 상태를 함께 보여주는
      현황 표를 담았다. design.md가 후보로 적었던 `/wes/work-orders` +
      `/wes/waves` 2화면 분리는 하지 않았다 — 웨이브와 업무 오더를 한 화면에서
      같이 봐야 릴리즈 결과(어느 건이 나갔고 어느 건이 남았는지)를 이해할 수
      있어서다. 화면 조작 권한은 3.9의 역할 집합과 동일하게 게이팅한다.
- [x] 7.2 `frontend/playwright/e2e/wes-dispatch-flow.spec.ts` 추가 — 실제 UI로
      웨이브 개설 → 업무 오더 3건 큐잉 → 릴리즈 → (off-UI psql로 게이트웨이가
      완료 보고) → UI 재조회에서 업무 오더가 자동 `COMPLETED`로 전이한 것 확인 →
      재시도 → 실패 전파 → 취소 캐스케이드. 2개 테스트 모두 통과
      (`playwright-run.txt`).
- [x] 7.3 DOCX 운영자 매뉴얼 — `openspec/specs/wms_wes-material-flow-control/docs/build_manual.mjs`
      (area 1의 생성기와 같은 구조/스타일)로
      `wes-material-flow-control-operator-manual.docx`(1.2MB, 9개 실제 스크린샷)
      를 생성했다.
