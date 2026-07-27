## 0. 선행 조건 확인

- [x] 0.1 (확인 완료 — area 1은 `supabase/migrations/20260727_wcs_equipment_control.sql`로
      이미 구현·적용되어 있다.) `add-wcs-equipment-control-contract`(capability
      `wms_wcs-equipment-control`)의 마이그레이션이 대상 데이터베이스에 이미
      적용되어 있는지 확인한다. 적용되어 있지 않다면 그 변경의 tasks.md
      1~4장을 먼저 완료한다 — 이 변경의 뷰/함수는 `wms.equipment`,
      `wms.equipment_commands`, `wms.equipment_faults`가 존재함을 전제로
      한다(design.md "정직한 전제 확인" 참고).
- [x] 0.2 (확인 완료 — area 2도 `20260728_wes_material_flow_control.sql`로 이미
      구현되어 있어, 6장의 통합을 이번 변경에서 함께 완료했다.)
      `add-wes-material-flow-control`(capability
      `wms_wes-material-flow-control`)의 구현 여부를 확인만 하고, 이 변경의
      1~5장(스키마·RLS·RPC·MCP) 착수 조건으로 삼지 않는다 — design.md가
      명시하듯 이 변경의 DB 스키마는 area2에 의존하지 않는다. area2와의
      통합은 6장에서 별도로 다룬다.

## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 (구현: `supabase/migrations/20260730_wcs_bottleneck_routing.sql`)
      `supabase/migrations/`에 새 마이그레이션 파일을 추가하고
      `wms.wcs_routing_policies`, `wms.wcs_routing_overrides` 테이블을
      design.md 데이터 모델대로 생성한다. 파일 이름의 타임스탬프는
      `wms_wcs-equipment-control`의 마이그레이션보다 뒤여야 한다. "병목 감지
      임계값 정책 관리", "설비 수동 라우팅 제외" Requirement 검증.
- [x] 1.2 `equipment_type`, `wcs_routing_overrides.status`에 `CHECK` 제약을
      추가하고, `queue_depth_threshold > 0`, `fault_count_threshold > 0`
      제약을 추가한다.
- [x] 1.3 `unique (warehouse_id, equipment_type)`를
      `wms.wcs_routing_policies`에 추가한다. "같은 창고·설비 유형에 정책을
      중복 등록할 수 없다" 시나리오 검증.
- [x] 1.4 `wms.wcs_routing_overrides`에 `status='ACTIVE'`인 행에 대해서만
      `equipment_id`를 유니크하게 강제하는 부분 유니크 인덱스를 추가한다.
      "이미 제외된 설비를 중복으로 제외할 수 없다" 시나리오 검증.
- [x] 1.5 `wms.wcs_equipment_load_snapshot` 뷰를 design.md대로 생성한다
      (`wms.equipment`, `wms.equipment_commands`, `wms.equipment_faults` 조인,
      30분 고정 관찰 윈도우). "설비 부하·건강 신호 조회" Requirement 검증.
- [x] 1.6 `wms.wcs_equipment_bottleneck_status` 뷰를
      `wms.wcs_equipment_load_snapshot`과 `wms.wcs_routing_policies`를 조인해
      생성한다 — 정책이 없으면 시스템 기본값(`queue_depth_threshold=3`,
      `fault_count_threshold=1`)을 대체 적용하고, `is_bottleneck`,
      `bottleneck_reasons`, `is_excluded`를 계산한다. "임계값 기반 병목 감지"
      Requirement의 4개 시나리오 전부 검증. 두 뷰 모두 `security invoker`로
      정의해 기반 테이블의 RLS를 그대로 상속하는지 확인한다.
- [x] 1.7 `wms.wcs_select_available_equipment(p_tenant_id, p_warehouse_id,
      p_equipment_type, p_zone_code)` 함수를 design.md대로 구현한다 —
      `wms_wes-material-flow-control`의 기존 후보 조건(타입/구역 일치,
      `status='IDLE'`, 미종결 명령 없음)을 그대로 포함하고, 그 위에 이 계약의
      하드 제외(`wms.wcs_routing_overrides`)와 소프트 병목 회피
      (`wms.wcs_equipment_bottleneck_status.is_bottleneck`, 폴백 포함)를
      적용한 뒤, 최종 후보 그룹 안에서 기존 tie-break(최근 완료 건수 최소)를
      적용해 하나의 `equipment_id`(또는 `null`)를 반환한다. "가용 설비
      선택에 대한 병목 회피 반영" Requirement의 4개 시나리오를 이 함수를
      직접 psql로 호출해 단위 검증한다(area2 RPC 통합은 6장에서 별도 검증).
      **구현 시 조정**: 실제 area 2의 선택 헬퍼가 tie-break 관찰 윈도우를
      호출자에게서 받으므로, 이 함수에 기본값이 있는 5번째 파라미터
      `p_recent_window interval default interval '1 hour'`를 추가했다 —
      design.md가 문서화한 4-인자 호출 형태는 그대로 유효하다. 또한
      "그룹 분리 후 그룹 안에서 tie-break"라는 D5 규칙은 분기 없이
      `order by is_bottleneck, <area 2의 기존 정렬>` 한 줄로 동등하게 표현했다.
      (마이그레이션 헤더 DEVIATION 1 참고.)

## 2. RLS 정책

- [x] 2.1 2개 신규 테이블에 `enable row level security`를 적용하고, 기존
      테이블과 동일한 패턴(`warehouse_id in (select
      wms.current_warehouse_ids(tenant_id))`)의 `select` 정책만 추가한다.
      "테넌트·창고 단위 접근 통제" Requirement 검증.
- [x] 2.2 `authenticated`/`anon`에 신규 테이블의 `insert`/`update`/`delete` 권한을
      부여하지 않았는지, `wms.wcs_select_available_equipment`에
      `authenticated`로 `EXECUTE` 권한이 부여되지 않았는지 psql로 점검한다.
- [x] 2.3 교차 테넌트 접근 차단을 psql로 직접 검증한다(테넌트 A 사용자가
      테넌트 B 설비의 강제 제외/정책을 조회·조작할 수 없음). "다른 테넌트의
      설비 라우팅 정보에는 접근할 수 없다" 시나리오 검증.

## 3. Command RPC

- [x] 3.1 `wms.wms_register_wcs_routing_policy`를 구현한다 — 역할 검사
      (`WMS_ADMIN`, `WAREHOUSE_MANAGER`), 창고 스코프 검사, 중복
      `(warehouse_id, equipment_type)` 거부, `wms.idempotency_records` 연동,
      `wms.audit_events` 기록. "병목 감지 임계값 정책 관리" Requirement의
      등록 관련 시나리오 검증.
- [x] 3.2 `wms.wms_update_wcs_routing_policy`를 구현한다 — 정책 버전 검증.
      "정책의 임계값을 갱신한다", "버전이 어긋나면 갱신이 거부된다" 시나리오
      검증.
- [x] 3.3 `wms.wms_exclude_equipment_from_routing`를 구현한다 — 역할 검사
      (`WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR`), `reason` 필수 검증,
      기존 `ACTIVE` 제외 존재 시 거부. "설비 수동 라우팅 제외" Requirement의
      등록 관련 시나리오 검증.
- [x] 3.4 `wms.wms_clear_equipment_routing_exclusion`를 구현한다 — 제외
      레코드 버전 검증, 이미 `CLEARED`인 레코드 재해제 거부,
      `cleared_by`/`cleared_at` 기록. "제외를 해제해 자동 라우팅 대상으로
      복귀시킨다", "이미 해제된 제외를 다시 해제할 수 없다" 시나리오 검증.
- [x] 3.5 `wms.wms_get_equipment_routing_status`를 구현한다 —
      `wms.wcs_equipment_bottleneck_status`와 활성 제외 정보를 조인한
      읽기 전용 조회. "설비 부하·건강 신호 조회" Requirement 검증.
- [x] 3.6 5개 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다.
- [x] 3.7 감사 이벤트 커버리지를 psql로 점검한다 — 4개 쓰기 RPC 각각 성공 시
      `wms.audit_events`에 올바른 `command`/`entity_type`/`before`/`after`가
      기록되는지 확인. "감사 추적" Requirement의 2개 시나리오 검증.
- [x] 3.8 멱등성 재시도 테스트: 동일 `idempotency_key`로
      `wms_exclude_equipment_from_routing`을 2회 호출해 제외 레코드가 1건만
      생성되는지 확인한다.

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 기존 `@mcp.tool` 패턴을 따라 아래 도구를 추가한다:
      `register_wcs_routing_policy`, `update_wcs_routing_policy`,
      `exclude_equipment_from_routing`, `clear_equipment_routing_exclusion`,
      `get_equipment_routing_status`. `wms.wcs_select_available_equipment`는
      MCP 도구로 노출하지 않는다(design.md).
- [x] 4.2 각 쓰기 도구 반환값에 `next_actions`를 채운다(예:
      `exclude_equipment_from_routing` → `["clear_equipment_routing_exclusion"]`).
- [x] 4.3 `docs/03-processgpt-integration.md`의 에이전트 tool 허용 목록 표에
      `PROCESS_AGENT`는 이 계약의 어떤 쓰기 도구에도 포함하지 않는다는 점을
      note로 남긴다(design.md 역할 모델 — 임계값 조정과 강제 제외는 사람의
      운영 판단). `get_equipment_routing_status`(읽기)만 `PROCESS_AGENT`
      허용 목록에 추가한다.

## 5. E2E 검증 (`openspec/specs/wms_wcs-bottleneck-routing/e2e/`에 응집)

- [x] 5.1 area1의 소프트웨어 시뮬레이터를 이용해 설비 여러 대에 명령을
      쌓아 큐 길이를 임계값 이상으로 만들고, 라우팅 현황 조회에서
      `is_bottleneck=true`, `bottleneck_reasons`에 `QUEUE_DEPTH_EXCEEDED`가
      포함되는지 확인한다. "임계값 기반 병목 감지" Requirement 검증.
- [x] 5.2 시뮬레이터로 같은 설비에 장애를 반복 발생시켜
      `FAULT_FREQUENCY_EXCEEDED` 판정을 재현한다.
- [x] 5.3 강제 제외 → 해제 왕복을 psql/Python으로 검증한다: 제외 등록 →
      `wms.wcs_select_available_equipment`가 그 설비를 후보에서 제외하는지
      직접 함수 호출로 확인 → 해제 → 다시 후보에 포함되는지 확인.
- [x] 5.4 교차 테넌트/역할 오류 케이스(`FORBIDDEN`)와 버전 충돌 케이스
      (`CONFLICT`)를 psql로 직접 호출해 확인한다.
- [x] 5.5 시뮬레이터 스크립트, 실행 결과를
      `openspec/specs/wms_wcs-bottleneck-routing/e2e/` 아래에 정리한다.

## 6. area2 통합 조정 (구현 통합 의존성 — DB 마이그레이션과 별개)

- [x] 6.1 area2는 **이미 구현되어 있었다**. 다만 design.md가 가정한 "세 RPC
      각각의 인라인 쿼리"가 아니라, 세 RPC가 모두
      `wms._wms_try_dispatch_work_order` → `wms._wms_pick_equipment_for_work_order`
      (whole-row 파라미터·whole-row 반환) 하나로 모이는 구조였다. 따라서
      리팩터링 방향을 뒤집어, 이 변경의 마이그레이션 안에서
      `create or replace function wms._wms_pick_equipment_for_work_order(...)`로
      그 헬퍼를 `wms.wcs_select_available_equipment` 위임 어댑터로 교체했다 —
      `20260728_wes_material_flow_control.sql` 파일은 수정하지 않았고,
      시그니처·반환 타입·"후보 없음 = all-null row" 계약도 그대로다. 단일
      choke point 덕분에 area2의 세 디스패치 경로가 한 번에 적용된다.
      (README `Documented deviations` 1번, 마이그레이션 헤더 DEVIATION 1.)
- [x] 6.2 area2의 디스패치 경로(WAVELESS 업무 오더 등록, 웨이브 릴리즈,
      재디스패치)를 통해 강제 제외/병목 회피가 실제로 반영되는지 end-to-end로
      검증한다 — "강제 제외된 설비만 후보일 때는 선택되지 않는다" 시나리오를
      함수 단위가 아니라 area2의 실제 RPC 호출로 재현한다. "가용 설비 선택에
      대한 병목 회피 반영" Requirement의 4개 시나리오 전부를 이 경로로
      재검증한다.
- [x] 6.3 해당 없음으로 종결 — 6.1/6.2가 이번 변경에서 함께 완료되어,
      design.md Risks의 "함수 존재만으로 완료 처리하지 않는다"는 조건이
      실제 디스패치 경로 왕복(psql 시뮬레이터 §8, MCP 왕복 4~6단계,
      Playwright 5~8단계)으로 충족되었다. 반대 방향의 회귀(area2 기존
      동작 유지)도 전체 Playwright 스위트 9/9 통과로 확인했다.

## 7. 문서/카탈로그 갱신

- [x] 7.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "지능형
      라우팅/병목 해소" 행에 "스펙 완료 → `wms_wcs-bottleneck-routing`"
      비고를 추가한다(이미 이 변경과 함께 완료됨 — 회귀 확인용 항목).
- [x] 7.2 이 변경이 archive될 때
      `openspec/specs/wms_wcs-bottleneck-routing/spec.md`로 동기화되는지
      확인한다(`openspec archive` 절차).

## 8. 프론트엔드

> design.md는 화면을 이 변경의 범위 밖으로 남겼지만, 다른 세 영역과 마찬가지로
> "계약이 실제로 사람의 화면에서 동작하는가"를 확인할 수 있어야 한다고 판단해
> 함께 구현했다(design.md "프론트엔드 확장 지점" 절이 지정한 위치 그대로).

- [x] 8.1 `frontend/src/views/WcsRoutingView.vue`를 추가하고
      `frontend/src/router/index.ts`에 `/wcs/routing` 라우트를,
      `frontend/src/App.vue` 사이드 내비게이션에 `WCS Routing` 항목을 추가했다.
      한 번의 `wms_get_equipment_routing_status` 호출로 설비별 부하·병목·제외
      현황과 창고의 임계값 정책 목록을 모두 채운다.
- [x] 8.2 역할별 화면 분기: 임계값 편집은 `WMS_ADMIN`/`WAREHOUSE_MANAGER`에게만,
      강제 제외/해제는 여기에 `WCS_OPERATOR`를 더한 집합에게만 노출하고,
      `WCS_OPERATOR`에게는 그 이유를 노란 띠로 명시한다(숨기지 않는다).
- [x] 8.3 `frontend/playwright/e2e/wcs-routing-flow.spec.ts` 추가 — 라우팅
      보드의 판정과 `/wes/dispatch`의 **실제 배정 결과**를 항상 짝지어 검증한다.
      전체 스위트 9개 테스트 통과(`openspec/specs/wms_wcs-bottleneck-routing/e2e/playwright-run.txt`).
- [x] 8.4 캡처한 13장의 스크린샷으로 DOCX 운영자 매뉴얼을 생성했다
      (`openspec/specs/wms_wcs-bottleneck-routing/docs/build_manual.mjs` →
      `wcs-bottleneck-routing-operator-manual.docx`, 앞선 세 매뉴얼과 동일한
      생성기 형태).

## 9. 구현 중 발견한 선행 계약과의 불일치 (README에 근거 기록)

- [x] 9.1 area 2의 후보 선택은 인라인 쿼리 3개가 아니라 whole-row 헬퍼 1개였다
      → 위임 어댑터 방식으로 통합(6.1).
- [x] 9.2 `QUEUE_DEPTH_EXCEEDED`는 후보 선택에 구조적으로 도달할 수 없다 —
      area 2의 후보 조건이 이미 "미종결 명령 없음"을 요구하므로 모든 후보의
      `queue_depth`는 0이고, 그런 설비는 area 1의 상태 동기화로 이미 `RUNNING`이다.
      실제 소프트 회피를 구동하는 것은 `FAULT_FREQUENCY_EXCEEDED`다. 지표는
      제거하지 않고 모니터링 신호로 유지하되, 시뮬레이터 §4·README·DOCX 매뉴얼의
      "알아 두면 좋은 한계"에 명시했다.
- [x] 9.3 `WCS_OPERATOR`의 권한 경계(제외 가능·임계값 불가)를 화면과 시뮬레이터
      양쪽에서 드러냈다.
- [x] 9.4 강제 제외는 진행 중 명령을 취소하지 않는다 — 그런 경우
      `IN_FLIGHT_COMMANDS_NOT_CANCELLED` 경고를 반환하고 UI/매뉴얼에서 대처
      방법을 안내한다(스펙에 명시되지 않았던 공백을 조용히 반만 처리하지 않음).
