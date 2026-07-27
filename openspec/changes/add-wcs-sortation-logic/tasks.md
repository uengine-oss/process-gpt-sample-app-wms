## 0. 선행 조건 확인

- [x] 0.1 `add-wcs-equipment-control-contract`(capability `wms_wcs-equipment-control`)의
      마이그레이션이 대상 데이터베이스에 이미 적용되어 있는지 확인한다. 적용되어
      있지 않다면 그 변경의 tasks.md 1~4장을 먼저 완료한다 — 이 변경의 모든
      DB 작업은 `wms.equipment`, `wms.equipment_commands`,
      `wms.equipment_status_events`, `wms_dispatch_equipment_command`,
      `wms_report_command_result`, `wms_raise_equipment_fault`가 존재함을
      전제로 한다(design.md "정직한 전제 확인" 참고).
      → **해소됨**: `20260727_wcs_equipment_control.sql`과
      `20260728_wes_material_flow_control.sql`이 모두 구현·적용되어 있다.
      design.md/proposal.md의 "아직 미구현" 서술은 작성 시점 기준이며 더 이상
      사실이 아니다. `wms_raise_equipment_fault`의 실제 시그니처는
      `(p_equipment_id uuid, p_fault_code text, p_severity text, p_actor_id uuid,
      p_idempotency_key uuid, p_correlation_id text default null)`이고, 이 변경의
      자동 승격 트리거가 그대로 호출한다.
- [x] 0.2 선행 변경이 실제로 적용한 `wms.equipment_commands.command_type` `CHECK`
      제약의 이름을 `information_schema.table_constraints`로 확인하고, 이 변경의
      마이그레이션(1.2)에서 그 이름으로 `drop constraint`를 수행하도록 반영한다
      (design.md Risks 참고 — 이름이 다르면 마이그레이션이 실패한다).
      → 실제 제약명은 `equipment_commands_command_type_check`(Postgres 자동 생성)로
      확인되어 그대로 사용했다.
      → **추가로 발견된 불일치(DEVIATION 1)**: `wms_dispatch_equipment_command`가
      함수 본문에서도 `command_type` 목록을 하드코딩하고 있어 `CHECK` 제약만
      교체하면 `DIVERT`가 여전히 RPC 단계에서 거부된다. design.md D3의 "RPC 자체는
      수정하지 않는다"를 문자 그대로 지킬 수 없으므로, 이 변경의 마이그레이션에서
      그 함수를 `create or replace`하되 **그 목록 한 줄만** 확장했다(선행 변경의
      마이그레이션 파일은 손대지 않음). 근거는 마이그레이션 헤더와
      `openspec/specs/wms_wcs-sortation-logic/e2e/README.md`에 기록.

## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/20260729_wcs_sortation_logic.sql`에
      `wms.sortation_profiles` 테이블을 design.md 데이터 모델대로 생성했다.
      타임스탬프는 선행 3개 마이그레이션보다 뒤다.
- [x] 1.2 `wms.equipment_commands.command_type` `CHECK` 제약을 교체해 `DIVERT`,
      `SET_SPEED`를 추가했다(0.2의 실제 제약명 사용). 원 테이블 정의는
      수정하지 않았다. 위 DEVIATION 1에 따라 디스패치 RPC의 동일 목록도 함께
      확장했다.
- [x] 1.3 `wms.equipment_commands`에 `BEFORE INSERT` 트리거
      (`equipment_commands_validate_sortation`)를 추가했다 — 설비 유형 검사,
      프로파일 존재/`ACTIVE` 검사, `DIVERT`의 `target_chute`/`item_identifier`
      필수 + `expected_gap_mm` 양수 검사, `SET_SPEED`의 `speed_mode`/`speed_unit`
      일치/`speed_value` 범위 검사. 시뮬레이터 §3·§4가 전 시나리오를 재현한다.
- [x] 1.4 `wms.equipment_status_events`에 `BEFORE INSERT` 트리거
      (`equipment_status_events_validate_sortation_outcome`)를 추가했다 —
      `DIVERT` 명령의 `COMMAND_COMPLETED`/`COMMAND_FAILED` 이벤트에서
      `SUCCESS↔COMPLETED`, `MISROUTE`/`JAM↔FAILED` 정합성과 outcome 값 집합을
      검증한다. 시뮬레이터 §5.
- [x] 1.5 `wms.equipment_status_events`에 `AFTER INSERT` 트리거
      (`equipment_status_events_escalate_sortation_jam`)를 추가했다 —
      `wms_raise_equipment_fault`를 직접 호출해 `SORTATION_JAM`/`CRITICAL` 장애를
      발생시키고, 이미 `FAILED`로 전이된 잼 명령 자신도 그 장애에 연결한다
      (버전은 올리지 않음 — 호출자에게 이미 반환된 버전을 어긋나게 하지 않기
      위해). `MISROUTE`는 반응하지 않음을 시뮬레이터 §5 말미에서 확인. 시뮬레이터 §6.
- [x] 1.6 `speed_mode`/`status` `CHECK`, `min_speed_value <= max_speed_value`
      `CHECK`, `unique (equipment_id)`를 모두 추가했다.

## 2. RLS 정책

- [x] 2.1 `wms.sortation_profiles`에 RLS를 켜고 기존 패턴의 `select` 정책만
      추가했다(`warehouse_id in (select wms.current_warehouse_ids(tenant_id))`).
- [x] 2.2 `information_schema.role_table_grants` 점검을 시뮬레이터 §7에 넣었다 —
      `authenticated`에 `SELECT`만 부여되어 있고 직접
      `INSERT`/`UPDATE`/`DELETE`는 "permission denied"임을 확인.
- [x] 2.3 교차 테넌트 차단을 시뮬레이터 §1·§7에서 확인했다(테넌트 B는 프로파일
      등록 시 `FORBIDDEN`, 조회 0건, 읽기 RPC도 `FORBIDDEN`).

## 3. Command RPC

- [x] 3.1 `wms.wms_create_sortation_profile` 구현 — 역할(`WMS_ADMIN`,
      `WAREHOUSE_MANAGER`, `WCS_OPERATOR`), 창고 스코프, `equipment_type`,
      중복 프로파일, 값 범위 검증 + 멱등성 + 감사 이벤트.
- [x] 3.2 `wms.wms_update_sortation_profile` 구현 — `expected_version` 기반
      낙관적 동시성, null 파라미터는 "유지", 진행 중 명령이 있으면
      `IN_FLIGHT_COMMANDS_NOT_REVALIDATED` 경고.
- [x] 3.3 `wms.wms_get_sortation_profile` 구현 — 창고의 SORTER/CONVEYOR 전체를
      프로파일(없으면 null), 진행 중 분류 명령, 마지막 outcome, 열린 장애와
      함께 반환.
- [x] 3.4 3개 RPC 전부 `grant execute ... to authenticated`.
- [x] 3.5 감사 이벤트 커버리지 점검(시뮬레이터 §9, Playwright 테스트 2).
      → **DEVIATION 3**: spec.md "감사 추적"이 요구한 "payload 검증 거부"의 감사
      기록은 물리적으로 불가능하다 — 거부는 `RAISE EXCEPTION`이라 같은 트랜잭션에
      쓴 감사 행까지 롤백된다(자율 트랜잭션 수단이 이 저장소에 없음). 대신 성공
      쓰기 전부와 자동 승격을 기록하며, 자동 승격은 area 1의 감사 행이 담지 못하는
      설비 상태 전이(`RUNNING → FAULT`)를 담기 위해 별도
      `wms_escalate_sortation_jam` 행을 추가로 남긴다.
- [x] 3.6 멱등성 재시도 테스트(시뮬레이터 §8) — 동일 키 2회 호출이 동일 응답을
      반환하고 프로파일은 1건만 생성됨.
- [x] 3.7 `wms_dispatch_equipment_command`를 통한 트리거 통합 검증 — 시뮬레이터
      §3·§4의 모든 거부가 그 RPC의 `INVALID:` 경로로 그대로 노출됨을 확인.
      (그 RPC는 0.2 DEVIATION 1의 한 줄을 제외하고 동작이 동일하다.)

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 `create_sortation_profile`, `update_sortation_profile`,
      `get_sortation_profile` 3종 추가. `DIVERT`/`SET_SPEED` 전용 도구는 만들지
      않았고, 그 사실과 payload 규격을 섹션 주석 + `get_sortation_profile`
      docstring에 적었다(`mcp_roundtrip.py`가 `dispatch_sortation_command`가
      존재하지 **않음**을 어서션으로 고정). 기존 `dispatch_equipment_command`의
      `command_type` 설명에도 두 값을 추가했다.
- [x] 4.2 쓰기 도구 반환값에 `next_actions`를 채웠다
      (`create_sortation_profile` → `["dispatch_equipment_command",
      "get_sortation_profile", "update_sortation_profile"]`).
- [x] 4.3 `docs/03-processgpt-integration.md` 허용 목록에 `wms.get_sortation_profile`만
      추가하고, 프로파일 쓰기 2종이 `PROCESS_AGENT`에게 `FORBIDDEN`인 이유와
      분류 명령이 기존 디스패치 도구를 재사용한다는 점을 note로 적었다.

## 5. E2E 검증 (`openspec/specs/wms_wcs-sortation-logic/e2e/`에 응집)

- [x] 5.1 happy path 왕복 검증 — `simulator.sql` §0~§5(등록 → 프로파일 → DIVERT
      → `outcome=SUCCESS` COMPLETED 보고), `mcp_roundtrip.py`가 같은 경로를 MCP
      도구 계층으로 재실행.
- [x] 5.2 속도 조정 경로 검증 — 범위 안/밖, 단위 불일치, `FIXED`인데 값 누락,
      알 수 없는 모드, `AUTO`(값 없이 성공)까지 시뮬레이터 §4.
- [x] 5.3 잼 자동 장애 승격 시나리오 — 시뮬레이터 §6 및 Playwright 5~6단계.
      두 명령 모두 `FAILED`, 두 명령 모두 새 장애에 연결, 이후 `WCS_OPERATOR`가
      해소해 `IDLE` 복귀까지 확인.
- [x] 5.4 오분류 시나리오 — 명령만 `FAILED`, 설비 상태 유지, 장애 0건
      (시뮬레이터 §5, Playwright 4단계 + `/wcs/monitor`에 장애 배너 없음).
- [x] 5.5 `FORBIDDEN`(역할·교차 테넌트)과 `CONFLICT`(버전) 케이스를 psql로 직접
      확인(시뮬레이터 §1·§2·§7).
- [x] 5.6 `simulator.sql` / `simulator-run.txt` / `mcp_roundtrip.py` /
      `mcp_roundtrip-run.txt` / `playwright-run.txt` / `screenshots/`(14장) /
      `README.md`를 `openspec/specs/wms_wcs-sortation-logic/e2e/`에 정리했다.
      `playwright-run.txt`는 이 스펙만이 아니라 **전체 스위트 7개 테스트**의
      실행 결과다(선행 영역 회귀 없음).

## 6. 문서/카탈로그 갱신

- [x] 6.1 `docs/04-wms-wcs-market-feature-catalog.md` §5의 "고속 분류 제어
      (Sortation Logic)" 행이 이미 "스펙 완료 → `wms_wcs-sortation-logic`"으로
      기록되어 있음을 확인했다(회귀 없음).
- [x] 6.2 archive 시 `openspec/specs/wms_wcs-sortation-logic/spec.md`로
      동기화되는 절차를 확인했다. 선행 두 영역과 동일하게 이 변경도 아직
      archive하지 않았으므로 `openspec/specs/wms_wcs-sortation-logic/`에는
      검증 산출물(`e2e/`, `docs/`)만 둔다.
- [x] 6.3 §5 표의 "미착수 영역" 목록과 대조해 후속 영역(지능형 라우팅/병목 해소,
      서열 출고/지능형 적재, 디지털 트윈/시뮬레이션)이 모두 별도 change로
      존재함을 확인했다(`add-wcs-bottleneck-routing`,
      `add-wcs-sequential-dispatch`, `add-wcs-digital-twin-simulation`).
- [x] 6.4 (추가) DOCX 운영자 매뉴얼을
      `openspec/specs/wms_wcs-sortation-logic/docs/`에 생성했다 —
      `build_manual.mjs`(선행 두 영역과 동일한 생성기 형태)와 그 산출물
      `wcs-sortation-logic-operator-manual.docx`. 모든 화면은 통과한 Playwright
      실행에서 캡처한 실제 프레임이다.

## 7. 프론트엔드

> 원안은 이 변경에서 화면을 만들지 않기로 했으나(아래 7.1의 원문), 구현
> 단계에서 범위를 넓혀 화면까지 함께 구현하기로 했다. design.md
> "프론트엔드 확장 지점"이 제안한 위치를 그대로 따랐다.

- [x] 7.1 (당초 연기 → 구현함) `frontend/src/views/WcsSortationView.vue`를 추가하고
      `frontend/src/router/index.ts`에 `/wcs/sortation` 라우트를,
      `frontend/src/App.vue` 사이드바에 "WCS Sortation" 링크를 추가했다.
      화면은 설비별 카드로 (a) 프로파일 등록/수정(상태 ACTIVE·INACTIVE 토글 포함),
      (b) `DIVERT` 전송(슈트·아이템 식별자·선택 간격), (c) `SET_SPEED` 전송
      (FIXED/AUTO, 단위는 프로파일에서 자동 사용), (d) 진행 중 분류 명령과 마지막
      분류 결과 배지를 제공한다. 명령은 새 RPC 없이
      `wms_dispatch_equipment_command`를 그대로 호출한다.
      경로는 design.md가 제안한 `/wcs/sortation-profiles` 대신
      `/wcs/sortation`으로 잡았다 — 화면이 프로파일 관리와 명령 전송을 함께
      다루므로 "profiles"라는 이름이 실제 내용보다 좁다.
- [x] 7.2 (추가) 역할 구분을 화면에 드러냈다 — 프로파일 관리 가능
      (`WMS_ADMIN`/`WAREHOUSE_MANAGER`/`WCS_OPERATOR`)과 명령 전송 가능
      (`WAREHOUSE_MANAGER`/`WCS_OPERATOR`/`PROCESS_AGENT`)이 다르므로,
      `WMS_ADMIN`에게는 프로파일 편집만 보이고 그 이유를 안내 문구로 표시한다
      (0.2 DEVIATION 2). Playwright 테스트 2가 이 화면 차이를 고정한다.
- [x] 7.3 (추가) `frontend/playwright/e2e/wcs-sortation-flow.spec.ts` 작성 —
      프로파일 등록 → 범위 밖 속도 거부 → `DIVERT` 전송 → off-UI `MISROUTE`
      (장애 없음) → off-UI `JAM`(자동 장애, `/wcs/monitor`에서 확인) → 운영자
      해소 → 재가동. 픽스처는 전용 코드(`SORT-E2E-01/02`)와 전용 존
      (`ZONE-SORT-E2E`)을 쓰고 `afterAll`에서 지운다 — 선행 스펙들의 strict
      locator와 충돌하지 않게 하기 위한 area 2의 교훈을 그대로 적용했다.
      전체 스위트(7개) 통과 확인.
