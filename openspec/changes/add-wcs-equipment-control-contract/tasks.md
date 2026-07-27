## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/`에 새 마이그레이션 파일(예:
      `<timestamp>_wms_wcs_equipment_control.sql`)을 추가하고 `wms.equipment`,
      `wms.equipment_commands`, `wms.equipment_status_events`,
      `wms.equipment_faults` 테이블을 design.md 데이터 모델대로 생성한다.
      "자동화 설비 등록" Requirement 검증.
      → `supabase/migrations/20260727_wcs_equipment_control.sql`.
      `equipment_status_events`에는 design.md 표에 없는 `seq bigserial`을 추가했다
      — 한 트랜잭션에서 여러 이벤트가 같은 `created_at`을 갖기 때문에
      모니터링 피드의 순서를 결정론적으로 만들려면 tiebreaker가 필요하다.
- [x] 1.2 `equipment_type`, `status`(설비/명령/장애 각각), `command_type`,
      `severity`에 `CHECK` 제약을 추가해 스펙에 정의된 값 집합만 허용되게 한다.
      "정의되지 않은 상태 값은 거부된다", "명령 타입" 관련 시나리오 검증.
      → CHECK 제약에 더해 각 RPC가 값을 먼저 검사해 `INVALID:` 접두 예외를
      던진다(제약 위반 메시지는 접두 규약을 따르지 않으므로).
      `event_type`에는 design.md 목록에 없는 `COMMAND_CANCELLED`를 추가했다
      (명령 취소도 모니터링 피드에 보여야 한다).
- [x] 1.3 `unique (warehouse_id, equipment_code)` 제약을 추가한다. "같은 창고에서
      설비 코드를 중복 등록할 수 없다" 시나리오 검증.
- [x] 1.4 `wms.memberships.role`이 자유 텍스트임을 확인하고(체크 제약이 없다면
      추가하지 않음), 시드 데이터에 `WCS_OPERATOR`, `WCS_GATEWAY` 역할을 가진
      데모 사용자를 최소 1명씩 추가한다.
      → `role`에 CHECK 제약 없음을 확인(제약 추가하지 않음).
      `supabase/seed.sql`에 `wcs-operator-a@demo.local`,
      `wcs-gateway-a@demo.local`(둘 다 `Demo1234!`, 테넌트 A, 창고 A 스코프) 추가.

## 2. RLS 정책

- [x] 2.1 4개 신규 테이블에 `enable row level security`를 적용하고, 기존
      테이블과 동일한 패턴(`warehouse_id in (select
      wms.current_warehouse_ids(tenant_id))`)의 `select` 정책만 추가한다.
      "테넌트·창고 단위 접근 통제" Requirement 검증.
- [x] 2.2 `authenticated`/`anon`에 신규 테이블의 `insert`/`update`/`delete` 권한을
      부여하지 않았는지 확인하는 psql 점검 스크립트를 작성한다(기존 D3 원칙
      회귀 방지).
      → `e2e/simulator.sql` §8.1이 `information_schema.role_table_grants`를
      조회해 `authenticated`에 `SELECT`만 있고 `anon`에는 아무 권한도 없음을
      확인한다. §7.4는 직접 INSERT/UPDATE/DELETE가 "permission denied"로
      거부되는 것을 실제로 호출해 확인한다.
- [x] 2.3 교차 테넌트 접근 차단을 psql로 직접 검증한다(테넌트 A 사용자가 테넌트
      B 설비를 조회/명령할 수 없음). "다른 테넌트의 설비에는 접근할 수 없다"
      시나리오 검증.
      → §1.6/§3.6/§7.2/§7.3. 테넌트 B admin은 4개 테이블 모두에서 0행을 보고,
      테넌트 A 설비에 대한 등록·디스패치는 `FORBIDDEN`으로 거부된다.

## 3. Command RPC

- [x] 3.1 `wms.wms_register_equipment`를 구현한다 — 역할 검사(`WMS_ADMIN`,
      `WAREHOUSE_MANAGER`), 창고 스코프 검사, 중복 `equipment_code` 거부,
      `wms.idempotency_records` 연동, `wms.audit_events` 기록. "자동화 설비 등록"
      Requirement의 3개 시나리오 전부 검증.
- [x] 3.2 `wms.wms_dispatch_equipment_command`를 구현한다 — `expected_version`
      기반 낙관적 동시성, `FAULT` 상태 설비에 대한 거부, `linked_entity_type`/
      `linked_entity_id` 선택적 저장. "제어 명령 디스패치" Requirement의 4개
      시나리오 전부 검증.
      → 스펙이 명시한 `FAULT`에 더해 `MAINTENANCE` 설비도 거부한다(점검 중
      설비에 명령을 보내는 것은 `FAULT`와 같은 이유로 안전하지 않다).
- [x] 3.3 `wms.wms_report_command_result`를 구현한다 — 명령 버전 검증,
      `COMPLETED`/`FAILED` 시 설비 상태 파생 갱신, `linked_entity_id`가 있으면
      해당 엔티티 대상 감사 이벤트 추가 기록. "명령 결과 보고" Requirement의 3개
      시나리오 전부 검증.
- [x] 3.4 `wms.wms_report_equipment_status`를 구현한다 — 설비 버전 검증, 이전/새
      상태를 포함한 이벤트 기록. "설비 상태 변경 보고" Requirement 검증.
      → `new_status='FAULT'`는 이 RPC로 허용하지 않는다(`INVALID`) — 장애 전이는
      진행 중 명령을 함께 종결해야 하므로(D4) `wms_raise_equipment_fault`만
      통과시킨다.
- [x] 3.5 `wms.wms_raise_equipment_fault`를 구현한다 — 장애 레코드 생성, 설비
      상태를 `FAULT`로 전환, 해당 설비의 미종결 명령(`PENDING`/`ACKNOWLEDGED`/
      `IN_PROGRESS`)을 일괄 `FAILED`로 전환하며 `fault_id` 연결. "설비 장애 발생
      처리" Requirement의 2개 시나리오 전부 검증.
- [x] 3.6 `wms.wms_resolve_equipment_fault`를 구현한다 — `WCS_GATEWAY` 호출
      거부, `resolution_note` 필수 검증, 장애/설비 상태 전환. "설비 장애 해소"
      Requirement의 3개 시나리오 전부 검증.
      → 같은 설비에 다른 `OPEN` 장애가 남아 있으면 설비를 `FAULT`로 유지하고
      `warnings`에 사유를 담는다.
- [x] 3.7 `wms.wms_cancel_equipment_command`를 구현한다 — 종결 상태 명령의 취소
      거부, 버전 검증. "명령 취소" Requirement의 2개 시나리오 전부 검증.
- [x] 3.8 `wms.wms_get_equipment_status`를 구현한다 — 설비 + 최근 이벤트 N건 +
      열린 장애를 조인한 읽기 전용 조회. "설비 목록·상태 조회" Requirement 검증.
      → `has_active_command`, `active_commands`, `open_faults`, `recent_events`
      (`p_event_limit`, 기본 5건)를 반환.
- [x] 3.9 8개 RPC 전부에 대해 `grant execute ... to authenticated`를 추가한다.
- [x] 3.10 감사 이벤트 커버리지를 psql로 점검한다 — 8개 쓰기 RPC 각각 성공 시
      `wms.audit_events`에 올바른 `command`/`entity_type`/`before`/`after`가
      기록되는지 확인. "감사 추적" Requirement의 2개 시나리오 검증.
      → 쓰기 RPC는 8개가 아니라 7개다(`wms_get_equipment_status`는 읽기 전용).
      `e2e/simulator.sql` §8.2~§8.4가 7개 전부 + 연결 엔티티(`receipt`)
      감사 행과, 장애 해소의 `before.status='OPEN'`/`after.status='RESOLVED'`를
      확인한다.
- [x] 3.11 멱등성 재시도 테스트: 동일 `idempotency_key`로 `dispatch_equipment_command`를
      2회 호출해 명령이 1건만 생성되는지 확인. "동일 idempotency_key 재시도는
      중복 명령을 만들지 않는다" 시나리오 검증.
      → §3.3/§3.4(디스패치)와 §1.4b(설비 등록) 둘 다 확인.

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 기존 `@mcp.tool` 패턴(파라미터에 `Annotated[..., Field(description=...)]`,
      `dry_run` 지원, `_error_result`/`WmsCommandError` 사용)을 따라 아래 도구를
      추가한다: `register_equipment`, `dispatch_equipment_command`,
      `report_command_result`, `report_equipment_status`, `raise_equipment_fault`,
      `resolve_equipment_fault`, `cancel_equipment_command`,
      `get_equipment_status`.
      → `dry_run`은 기존 파일의 관례를 그대로 따라 생성 계열 도구
      (`register_equipment`, `dispatch_equipment_command`)에만 두었다 — 기존
      `inspect`/`scrap`/`putaway`도 `dry_run`이 없다.
- [x] 4.2 각 쓰기 도구 반환값에 `next_actions`를 채운다(예:
      `dispatch_equipment_command` → `["report_command_result"]`,
      `raise_equipment_fault` → `["resolve_equipment_fault"]`).
- [x] 4.3 `docs/03-processgpt-integration.md`의 에이전트 tool 허용 목록 표에 이
      스펙에서 `PROCESS_AGENT`가 실제로 호출 가능한 도구(`dispatch_equipment_command`,
      `cancel_equipment_command`, `get_equipment_status`)만 추가하고,
      `report_command_result`/`report_equipment_status`/`raise_equipment_fault`/
      `resolve_equipment_fault`는 목록에서 제외한다는 점을 note로 남긴다(RLS에서도
      이미 `FORBIDDEN`으로 막힘 — 안전망 이중화, 기존 `inspect`/`scrap` 패턴과
      동일).
      → note에 `register_equipment`(`WMS_ADMIN`/`WAREHOUSE_MANAGER` 전용)도
      제외 대상으로 함께 적었다.
- [x] 4.4 (추가) 설비 쪽 피드백 도구가 실제로 동작하도록 `WCS_GATEWAY` service
      identity 로그인을 붙인다. `mcp/wms_mcp/client.py`에
      `get_gateway_client()`를, `config.py`에
      `WMS_WCS_GATEWAY_EMAIL`/`WMS_WCS_GATEWAY_PASSWORD`를 추가하고
      `mcp/.env.example`/`.env`를 갱신했다. `PROCESS_AGENT`를 해당 RPC의 허용
      역할에 끼워 넣는 대안은 기각했다 — spec.md "역할이 없는 사용자는 상태
      보고를 할 수 없다" 시나리오와 design.md D5가 두 아이덴티티의 분리를
      명시적으로 요구하기 때문이다.

## 5. E2E 검증 (`openspec/specs/wms_wcs-equipment-control/e2e/`에 응집)

- [x] 5.1 소프트웨어 시뮬레이터 스크립트(간단한 상태 머신, `WCS_GATEWAY` 자격으로
      RPC 직접 호출)를 작성해 "설비 등록 → 명령 디스패치 → ACK → IN_PROGRESS →
      COMPLETED" happy path를 psql/Python으로 왕복 검증한다.
      → `e2e/simulator.sql`(psql) + `e2e/mcp_roundtrip.py`(fastmcp `Client`).
- [x] 5.2 장애 시나리오를 시뮬레이터로 재현한다: `IN_PROGRESS` 명령이 있는
      설비에 장애를 발생시켜 명령이 `FAILED`로 전환되고 설비가 `FAULT`가 되는지,
      이후 `WCS_OPERATOR`가 장애를 해소해 `IDLE`로 돌아오는지 end-to-end로
      확인한다. "설비 장애 발생 처리", "설비 장애 해소" Requirement 검증.
- [x] 5.3 교차 테넌트/역할 오류 케이스(`FORBIDDEN`)와 버전 충돌 케이스
      (`CONFLICT`)를 psql로 직접 호출해 확인한다(기존 9개 RPC 검증 방식과 동일,
      `docs/03-processgpt-integration.md` "로컬 검증 기록" 절 참고).
- [x] 5.4 시뮬레이터 스크립트, 실행 결과, (있다면) 스크린샷을
      `openspec/specs/wms_wcs-equipment-control/e2e/` 아래에 정리한다.
      → `README.md`, `simulator.sql`, `simulator-run.txt`, `mcp_roundtrip.py`,
      `mcp_roundtrip-run.txt`, `playwright-run.txt`, `screenshots/`(11장).
- [x] 5.5 (추가) 브라우저 E2E: `frontend/playwright/e2e/wcs-equipment-flow.spec.ts`.
      사람 쪽(등록·디스패치·장애 해소)은 실제 UI로, 설비 쪽(`WCS_GATEWAY`)은
      화면 로그인 대상이 아니므로 `psql`로 직접 호출해(실제 PLC 게이트웨이가
      하는 것과 동일한 호출) happy path와 장애 경로를 왕복 검증한다. 기존
      `wms-flow.spec.ts`와 함께 3개 테스트 전부 통과.
      스펙 파일 자체는 `frontend/playwright/`에 둔다 — `playwright.config.ts`의
      `testDir`가 고정이라 openspec 디렉터리로 옮길 수 없다. 실행 결과와
      스크린샷만 `openspec/specs/.../e2e/`로 보낸다.

## 5b. 프론트엔드 화면 (7.1의 "연기" 결정을 이번 라운드에 뒤집음)

- [x] 5b.1 `frontend/src/views/WcsEquipmentView.vue`(`/wcs/equipment`) — 설비
      목록(코드·유형·구역·상태·버전·진행 중 명령), 설비 등록 폼
      (`WMS_ADMIN`/`WAREHOUSE_MANAGER`만), `IDLE` 설비에 대한 `MOVE` 디스패치.
- [x] 5b.2 `frontend/src/views/WcsMonitorView.vue`(`/wcs/monitor`) — 설비 상태,
      열린 장애, 최근 이벤트 피드, `resolution_note` 필수 입력을 갖춘 장애 해소
      액션(`WCS_OPERATOR`/`WAREHOUSE_MANAGER`/`WMS_ADMIN`만).
- [x] 5b.3 `src/router/index.ts`와 `src/App.vue` 사이드내비에 두 라우트 추가.
- [x] 5b.4 시드에 `wh-manager-a@demo.local`(`WAREHOUSE_MANAGER`) 추가 —
      design.md 역할 표가 참조하는 역할인데 데모 사용자가 없었다. 등록과
      디스패치를 모두 할 수 있는 유일한 사람 역할이라 UI 흐름에 필요하다.

## 5c. 운영자 매뉴얼 (DOCX)

- [x] 5c.1 Playwright 실행 중 단계별 전체 화면 스크린샷 11장을
      `openspec/specs/wms_wcs-equipment-control/e2e/screenshots/`에 캡처한다.
- [x] 5c.2 그 스크린샷으로 한국어 운영자 매뉴얼 DOCX를 생성한다 →
      `openspec/specs/wms_wcs-equipment-control/docs/wcs-equipment-control-operator-manual.docx`
      (생성 스크립트 `build_manual.mjs`, `docx` 스킬의 docx-js 경로 사용, 14쪽).
      표지 + 목차 + "시작하기 전에"(역할 구분·상태값 표) + 6개 단계 절 +
      "자주 만나는 메시지" 문제 해결 표. 테스트 리포트가 아니라
      `WAREHOUSE_MANAGER`/`WCS_OPERATOR`가 읽는 사용법 문서로 작성했다.
      `docx` 스킬의 `validate.py`로 검증 통과, LibreOffice로 PDF 렌더해 한글
      표시와 이미지 배치를 눈으로 확인했다.

## 6. 문서/카탈로그 갱신

- [x] 6.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "WCS 자동화 설비
      직접 제어"와 "실시간 모니터링/예외 복구" 행에 "스펙 완료 →
      `wms_wcs-equipment-control`" 비고를 추가한다.
      → 이 변경을 제안할 때 이미 반영되어 있었다(§5 표 확인 완료, 추가 편집 불필요).
- [ ] 6.2 이 변경이 archive될 때 `openspec/specs/wms_wcs-equipment-control/spec.md`로
      동기화되는지 확인한다(`openspec archive` 절차).
      → archive 시점 작업이므로 미완. 현재 `openspec/specs/wms_wcs-equipment-control/`
      에는 e2e 산출물만 있고 `spec.md`는 아직 없다(archive가 생성).

## 7. 프론트엔드

- [x] 7.1 ~~(연기)~~ `frontend/src/router/index.ts`에 `/wcs/equipment`,
      `/wcs/monitor` 라우트와 대응 `EquipmentView.vue`/`WcsMonitorView.vue`를
      추가한다.
      → **연기 결정을 뒤집어 이번 변경에서 구현했다.** 제품 책임자가 구현마다
      실제 Playwright E2E와 실 스크린샷 기반 매뉴얼을 요구했고, 둘 다 화면이
      있어야 성립하기 때문이다. 파일명은 design.md의 `EquipmentView.vue` 대신
      `WcsEquipmentView.vue`로 했다 — 기존 뷰들과 이름이 겹치지 않게 하기 위함.
      상세는 §5b 참조.
