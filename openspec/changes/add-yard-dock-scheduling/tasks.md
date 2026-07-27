## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/`에 새 마이그레이션 파일(예:
      `<timestamp>_wms_yard_dock_scheduling.sql`)을 추가하고 `wms.docks`,
      `wms.dock_appointments` 테이블을 design.md 데이터 모델대로 생성한다.
      "도크 등록", "도크 예약 생성" Requirement 검증.
      → `supabase/migrations/20260802_yard_dock_scheduling.sql`
- [x] 1.2 `create extension if not exists btree_gist;`를 추가하고,
      `wms.dock_appointments`에 `during tstzrange generated always as
      (tstzrange(scheduled_start, scheduled_end, '[)')) stored` 컬럼과
      `exclude using gist (dock_id with =, during with &&) where (status in
      ('SCHEDULED','CHECKED_IN','AT_DOCK'))` 제약을 추가한다. "도크 이중 예약
      방지" Requirement의 3개 시나리오 전부 검증.
      → 이 저장소에서 처음 켜지는 extension이다(`supabase/` 전체에
      `create extension` 없었음). 검증: `e2e/verify.sql` C1~C4 +
      `e2e/double_booking_concurrent.sh`
- [x] 1.3 `docks.status`, `dock_appointments.status`, `appointment_type`에
      `CHECK` 제약을 추가해 스펙에 정의된 값 집합만 허용되게 하고,
      `check (scheduled_end > scheduled_start)`, `check (appointment_type <>
      'INBOUND' or po_id is not null)` 제약을 추가한다. "시간창이 뒤집힌 예약",
      "INBOUND 예약에 po_id가 없으면 거부" 시나리오 검증.
      → 추가로 `dock_appointments_outbound_po_ck`(OUTBOUND는 po_id가 null),
      `dock_appointments_linked_pair_ck`(linked_entity_type/id는 함께)도 추가.
      검증: `e2e/verify.sql` B2/B3/B6
- [x] 1.4 `unique (warehouse_id, code)`를 `wms.docks`에 추가한다. "같은 창고에서
      도크 코드를 중복 등록할 수 없다" 시나리오 검증. → `e2e/verify.sql` A2
- [x] 1.5 시드 데이터에 도크 1~2개(`AVAILABLE` 상태)와 도크 예약 데모 케이스를
      최소 1건 추가한다.
      → `supabase/seed.sql`: 테넌트 A에 DOCK-01/02/03, 테넌트 B에 DOCK-B1(교차
      테넌트 검증용), 그리고 DOCK-03에 OUTBOUND 데모 예약 1건. 데모 예약을
      INBOUND로 만들지 않은 이유는 시드에 PO가 없고(있으면 `wms-flow.spec.ts`의
      `.first()` 셀렉터가 깨진다) INBOUND는 `po_id`가 필수이기 때문 — 주석으로
      남겨 뒀다.

## 2. RLS 정책

- [x] 2.1 2개 신규 테이블에 `enable row level security`를 적용하고, 기존
      테이블과 동일한 패턴(`warehouse_id in (select
      wms.current_warehouse_ids(tenant_id))`)의 `select` 정책만 추가한다.
      "테넌트·창고 단위 접근 통제" Requirement 검증.
- [x] 2.2 `authenticated`/`anon`에 신규 테이블의 `insert`/`update`/`delete` 권한을
      부여하지 않았는지 확인하는 psql 점검 스크립트를 작성한다(기존 D3 원칙
      회귀 방지). → `e2e/verify.sql` F6 (`information_schema.role_table_grants`)
      + F4c(실제로 `set local role authenticated` 후 INSERT/UPDATE 시도 →
      `permission denied`)
- [x] 2.3 교차 테넌트 접근 차단을 psql로 직접 검증한다(테넌트 A 사용자가 테넌트
      B 도크를 조회/예약할 수 없음). "다른 테넌트의 도크에는 접근할 수 없다"
      시나리오 검증. → `e2e/verify.sql` A4/F3/F4/F4b/F5.
      **주의**: psql은 superuser로 붙어 RLS를 우회하므로, F4 구간은
      `set local role authenticated`로 역할을 실제로 내려서 검사한다.

## 3. Command RPC

- [x] 3.1 `wms.wms_register_dock` — 역할 검사(`WMS_ADMIN`, `WAREHOUSE_MANAGER`),
      창고 스코프 검사, 중복 `code` 거부, `wms.idempotency_records` 연동,
      `wms.audit_events` 기록. → `e2e/verify.sql` A1~A4
- [x] 3.2 `wms.wms_set_dock_status` — `OCCUPIED` 상태에서 `CLOSED` 전환 거부,
      `expected_version` 검증. 추가로 `OCCUPIED`를 대상 상태로 지정하는 것도
      거부한다(점유는 파생 상태). → `e2e/verify.sql` B5/D3
- [x] 3.3 `wms.wms_schedule_dock_appointment` — `INBOUND`의 `po_id` 필수,
      시간창 검증, `CLOSED` 도크 거부, `exclusion_violation`(23P01) 캐치 후
      `CONFLICT:` 변환. → `e2e/verify.sql` B1~B6, C1~C4
- [x] 3.4 `wms.wms_cancel_dock_appointment` — `AT_DOCK` 이후 상태의 취소 거부,
      버전 검증. → `e2e/verify.sql` C4/D4/D8
- [x] 3.5 `wms.wms_check_in_vehicle` — `SCHEDULED` 전제조건, `carrier_name`/
      `vehicle_plate_no` 선택적 저장, 도크 상태 불변. 도크가 그 시점에
      점유 중이면 `DOCK_CURRENTLY_OCCUPIED` 경고를 함께 반환한다.
      → `e2e/verify.sql` D1/D3/D4
- [x] 3.6 `wms.wms_dock_vehicle` — `CHECKED_IN` 전제조건, 도크가 `OCCUPIED`/
      `CLOSED`면 거부, 예약·도크를 한 트랜잭션에서 갱신(도크 행은 `for update`로
      먼저 잠근다). → `e2e/verify.sql` D2/D3
- [x] 3.7 `wms.wms_depart_vehicle` — `AT_DOCK` 전제조건, 도크가 그 사이 `CLOSED`가
      아닐 때만 `AVAILABLE`로 복귀(그 경우 `DOCK_CLOSED_NOT_RELEASED` 경고).
      → `e2e/verify.sql` D4/D5/D6
- [x] 3.8 `wms.wms_get_dock_schedule` — 창고·기간 조건 읽기 전용 조회.
      도크별로 묶어 `dock_id`/`scheduled_start`/`scheduled_end`/`status`/
      `version`/`is_active`를 반환한다. → `e2e/verify.sql` F1/F2/F3
- [x] 3.9 8개 RPC 전부에 `grant execute ... to authenticated` 추가. 내부 헬퍼
      `wms._wms_load_dock_appointment`는 코어 스키마의
      `_wms_finalize_disposition`과 같이 grant하지 않는다.
- [x] 3.10 감사 이벤트 커버리지 psql 점검 — 7개 쓰기 RPC 각각의
      `command`/`entity_type`/`before`/`after`. → `e2e/verify.sql` H1/H2.
      `wms_dock_vehicle`/`wms_depart_vehicle`은 이벤트를 2건 남긴다
      (`dock_appointment` + `dock`).
- [x] 3.11 `wms_register_arrival`을 이 마이그레이션에서 전혀 수정하지 않았음을
      확인하고, 도크 예약 유무/상태와 무관하게 정상 동작하는지 psql로 검증한다.
      → `e2e/verify.sql` G1~G3 + Playwright 테스트 2의 역방향 단언
      (도크 RPC가 `receipt` 감사 이벤트를 남기지 않음)

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 8개 도구 추가: `register_dock`, `set_dock_status`,
      `schedule_dock_appointment`, `cancel_dock_appointment`, `check_in_vehicle`,
      `dock_vehicle`, `depart_vehicle`, `get_dock_schedule`.
      (실제 등록된 도구 총계 48 → 56. `grep -c '@mcp.tool'`은 49 → 57을
      돌려주지만 그중 1건은 모듈 docstring 4행의 산문이다 — FastMCP 레지스트리
      기준이 48/56.)
- [x] 4.2 각 쓰기 도구 반환값에 `next_actions`를 채운다
      (`schedule_dock_appointment` → `["check_in_vehicle", ...]`,
      `check_in_vehicle` → `["dock_vehicle", ...]`,
      `dock_vehicle` → `["depart_vehicle", "register_arrival"]`).
- [x] 4.3 `docs/03-processgpt-integration.md` 허용 목록에
      `schedule_dock_appointment`/`cancel_dock_appointment`/`get_dock_schedule`
      3종만 추가하고, 나머지 5종을 제외하는 이유를 note로 남겼다.

## 5. E2E 검증 (`openspec/specs/wms_yard-dock-scheduling/e2e/`에 응집)

- [x] 5.1 happy path 왕복 검증(도크 등록 → 예약 → 체크인 → 도킹(OCCUPIED) →
      출차(AVAILABLE 복귀)). → `e2e/verify.sql` A~D + Playwright 테스트 1
- [x] 5.2 이중 예약 동시성 재현 — 두 커넥션에서 거의 동시에 겹치는 예약 시도.
      → `e2e/double_booking_concurrent.sh` / `double-booking-run.txt`.
      두 번째 세션이 **블록되었다가** 첫 세션 커밋 시점에 `CONFLICT`로 실패하는
      것이 로그의 타임스탬프로 관찰된다(READ COMMITTED, advisory lock 없음).
- [x] 5.3 `wms_register_arrival`과의 독립성 end-to-end 확인(예약 없는 PO /
      `SCHEDULED` 예약만 있는 PO 둘 다 `ARRIVED`). → `e2e/verify.sql` G
- [x] 5.4 `FORBIDDEN`/`CONFLICT` 오류 케이스 psql 직접 호출 확인.
      → `e2e/verify.sql` A3/A4/D5/D7/F3/F5
- [x] 5.5 실행 스크립트·실행 결과·스크린샷을
      `openspec/specs/wms_yard-dock-scheduling/e2e/` 아래 정리.
      → `verify.sql`, `verify-run.txt`, `double_booking_concurrent.sh`,
      `double-booking-run.txt`, `playwright-run.txt`, `screenshots/`(14장),
      `README.md`

## 6. 문서/카탈로그 갱신

- [x] 6.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 "야드 및 도크 관리" 행
      갱신 — 스펙 완료에 더해 구현 산출물(마이그레이션/MCP/화면/E2E)과
      OUTBOUND 결정(D3-AMENDED)을 명시했다.
- [x] 6.2 archive 시 `openspec/specs/wms_yard-dock-scheduling/spec.md`로
      동기화되는지 확인(`openspec archive` 절차). 선행 6개 영역과 동일하게
      `openspec/specs/wms_yard-dock-scheduling/`에는 현재 `e2e/`와 `docs/`만
      두고 `spec.md`는 archive 시점에 동기화한다.

## 7. 프론트엔드 (원래 범위 밖 → 이번 구현에 포함)

- [x] 7.1 design.md "확장 지점"이 후속 작업으로 미뤄 뒀던 화면을 이번 변경에
      포함했다. 경로는 그 절이 지정한 대로 `/inbound/dock-schedule`.
      - `frontend/src/views/DockScheduleView.vue` — 도크 등록(관리자),
        도크 정비 Close/Reopen, PO 대상 예약 생성, 날짜별 도크×시간 타임라인,
        Check In / Dock Vehicle / Depart / Cancel 버튼. 캘린더 위젯이 아니라
        표로 만들었다(이 계약이 증명할 것은 "겹치는 예약이 불가능하다"이고
        표로도 똑같이 보인다).
      - `frontend/src/router/index.ts` — `dock-schedule` 라우트 추가.
      - `frontend/src/App.vue` — 화면이 13개가 되어 사이드바를 `WMS` /
        `WCS / WES` 두 그룹으로 나눴다(경로·라벨은 불변).
- [x] 7.2 Playwright E2E — `frontend/playwright/e2e/dock-schedule-flow.spec.ts`
      (`DOCK-E2E-*` 픽스처 네임스페이스, `afterAll` 정리). 예약 → UI 오류 배너로
      보이는 이중 예약 거부 → 체크인 → 도킹(도크 OCCUPIED) → 출차(AVAILABLE) →
      취소가 슬롯을 풀어 준다 → 재예약 성공, 그리고 역할 경계·감사 추적.
      결과: 이 스펙 2/2 통과, 전체 스위트 **15/15 통과**(회귀 없음).
- [x] 7.3 DOCX 사용자 매뉴얼 —
      `openspec/specs/wms_yard-dock-scheduling/docs/build_manual.mjs` →
      `yard-dock-scheduling-operator-manual.docx`(2.3MB, 스크린샷 14장 전부
      실제 Playwright 실행 프레임).
