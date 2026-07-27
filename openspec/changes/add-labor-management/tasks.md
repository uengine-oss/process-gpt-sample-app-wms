## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/`에 새 마이그레이션 파일(예:
      `<timestamp>_wms_labor_management.sql`)을 추가하고 `wms.labor_activities`
      테이블을 design.md 데이터 모델대로 생성한다. "인력 활동 시작 기록"
      Requirement 검증.
- [x] 1.2 `activity_type`, `status`에 `CHECK` 제약을 추가하고,
      `check (activity_type <> 'OTHER' or activity_label is not null)`,
      `check (status <> 'IN_PROGRESS' or completed_at is null)`,
      `check (status = 'IN_PROGRESS' or completed_at is not null)`,
      `check (unit_count is null or unit_count >= 0)` 제약을 추가한다.
      "OTHER 유형은 activity_label 없이 시작할 수 없다" 시나리오 검증.
- [x] 1.3 `duration_seconds`를 `completed_at - started_at`(초 단위) 생성
      컬럼으로 추가한다. "처리 수량과 함께 활동을 완료한다" 시나리오의
      `duration_seconds` 계산 검증.
- [x] 1.4 시드 데이터에 완료된 인력 활동을 최소 이틀치·두 역할
      (`INBOUND_OPERATOR`, `QUALITY_INSPECTOR`) 이상 추가해, 생산성 집계와
      리더보드 조회를 빈 데이터 없이 검증할 수 있게 한다.

## 2. RLS 정책

- [x] 2.1 `wms.labor_activities`에 `enable row level security`를 적용하고,
      design.md D3의 정책(`warehouse_id in (select
      wms.current_warehouse_ids(tenant_id)) and (actor_id = auth.uid() or
      wms.has_role(tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN'))`)을
      `select` 정책으로 추가한다. "개인 생산성 데이터 접근 통제" Requirement의
      2개 시나리오 전부 검증.
- [x] 2.2 `authenticated`/`anon`에 `insert`/`update`/`delete` 권한을 부여하지
      않았는지 확인하는 psql 점검 스크립트를 작성한다(기존 D3 원칙과 동일한
      회귀 방지 관례).
- [x] 2.3 교차 테넌트 접근 차단을 psql로 직접 검증한다(테넌트 A 사용자가
      테넌트 B의 인력 활동을 조회할 수 없음). "다른 테넌트의 인력 활동에는
      접근할 수 없다" 시나리오 검증.

## 3. Command RPC (쓰기)

- [x] 3.1 `wms.wms_start_labor_activity`를 구현한다 — 역할 검사
      (`INBOUND_OPERATOR`, `QUALITY_INSPECTOR`, `PROCESS_AGENT`, `WMS_ADMIN`),
      창고 스코프 검사, `p_actor_id = auth.uid()` 검증(`WMS_ADMIN` 예외,
      design.md D2), `activity_type='OTHER'`일 때 `activity_label` 필수 검증,
      `wms.idempotency_records` 연동, `wms.audit_events` 기록. "인력 활동
      시작 기록", "본인 명의 기록 원칙과 관리자 대리 기록" Requirement의
      시나리오 전부 검증.
- [x] 3.2 `wms.wms_complete_labor_activity`를 구현한다 — `IN_PROGRESS`
      전제조건 검증, `expected_version` 검증, `unit_count` 선택적 저장,
      `completed_at`/`duration_seconds` 기록. "인력 활동 완료 기록"
      Requirement의 3개 시나리오 전부 검증.
- [x] 3.3 `wms.wms_cancel_labor_activity`를 구현한다 — `IN_PROGRESS`
      전제조건 검증, `expected_version` 검증. "인력 활동 취소" Requirement
      검증.
- [x] 3.4 3개 쓰기 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다.
- [x] 3.5 감사 이벤트 커버리지를 psql로 점검한다 — 3개 쓰기 RPC 각각 성공 시
      `wms.audit_events`에 올바른 `command`/`entity_type`/`before`/`after`가
      기록되는지 확인한다. "인력 활동 감사 추적" Requirement 검증.

## 4. 조회 RPC (읽기, design.md D3 이중 검사)

- [x] 4.1 `wms.wms_get_labor_productivity`를 구현한다 — 창고 스코프 검사,
      호출자가 `WAREHOUSE_MANAGER`/`WMS_ADMIN`이 아니면 `actor_id =
      auth.uid()` 조건을 강제로 덧붙이는 필터링 로직, 작업자별·역할별·
      일자별·활동유형별 집계(완료 건수/평균·합계 처리 시간/합계 처리 수량),
      취소된 활동 제외. "작업자별 생산성 집계 조회" Requirement의 2개
      시나리오, "인력 활동 취소" Requirement의 집계 제외 조건 검증.
- [x] 4.2 `wms.wms_get_labor_leaderboard`를 구현한다 — 동일한 역할 기반
      필터링, `p_metric` 3종 지원, 정렬. "생산성 리더보드 조회" Requirement의
      2개 시나리오 전부 검증.
- [x] 4.3 `wms.wms_forecast_labor_demand`를 구현한다 — `WAREHOUSE_MANAGER`/
      `WMS_ADMIN` role 검사, 트레일링 `p_trailing_days`일 평균 시간당
      처리량 계산, 표본 없음(`INVALID:`) 처리, `recommended_headcount` 올림
      계산, 응답에 "단순 비율 계산이며 ML 예측이 아님"을 명시하는 필드 포함.
      "인력 수요 추정" Requirement의 3개 시나리오 전부 검증.
- [x] 4.4 3개 조회 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다.

## 5. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 5.1 기존 `@mcp.tool` 패턴(파라미터에 `Annotated[..., Field(description=...)]`,
      `dry_run` 지원, `_error_result`/`WmsCommandError` 사용)을 따라 아래
      도구를 추가한다: `start_labor_activity`, `complete_labor_activity`,
      `cancel_labor_activity`, `get_labor_productivity`,
      `get_labor_leaderboard`, `forecast_labor_demand`.
- [x] 5.2 기존 입고/검수/적치 도구 호출 지점(design.md D1) 예시로,
      `receive`/`inspect`/`putaway` 같은 기존 도구를 감싸 앞뒤로
      `start_labor_activity`/`complete_labor_activity`를 자동 호출하는
      래퍼 패턴을 참고 구현(레퍼런스 예시 1개)으로 추가하고, 나머지 도구
      통합은 후속 작업으로 tasks.md 7절에 남긴다.
- [x] 5.3 각 쓰기 도구 반환값에 `next_actions`를 채운다(예:
      `start_labor_activity` → `["complete_labor_activity",
      "cancel_labor_activity"]`).
- [x] 5.4 `docs/03-processgpt-integration.md`의 에이전트 tool 허용 목록 표에
      `PROCESS_AGENT`가 실제로 호출 가능한 도구(`start_labor_activity`,
      `complete_labor_activity`, `cancel_labor_activity`,
      `get_labor_productivity`)만 추가하고, `forecast_labor_demand`는
      제외한다는 점을 note로 남긴다(design.md D4, RLS/RPC 이중 검사에서도
      이미 `FORBIDDEN`으로 막힘 — 안전망 이중화, 기존 관례와 동일).

## 6. E2E 검증 (`openspec/specs/wms_labor-management/e2e/`에 응집)

- [x] 6.1 happy path를 psql/Python으로 왕복 검증한다: "활동 시작 → 완료(처리
      수량 포함) → 생산성 집계 조회에 반영 확인".
- [x] 6.2 프라이버시 시나리오를 재현한다: 작업자 A와 B가 각각 활동을 완료한
      뒤, A 계정으로 생산성 조회·리더보드 조회·테이블 직접 조회 3가지 모두
      B의 개별 데이터가 노출되지 않는지 확인하고, 관리자 계정으로는 둘 다
      노출되는지 확인한다. "작업자별 생산성 집계 조회", "생산성 리더보드
      조회", "개인 생산성 데이터 접근 통제" Requirement 전부 검증.
- [x] 6.3 인력 수요 추정을 표본 있음/없음 두 경우로 각각 호출해 결과와
      `INVALID:` 오류를 확인한다. "인력 수요 추정" Requirement 검증.
- [x] 6.4 기존 입고/검수/적치 RPC(`wms_register_arrival`, `wms_receive` 등)를
      이 마이그레이션에서 전혀 수정하지 않았음을 diff로 재확인하고, 인력
      활동 계측 여부와 무관하게 기존 RPC가 정상 동작하는지 psql로 직접
      검증한다(design.md D1의 "직교 계측" 전제 회귀 방지).
- [x] 6.5 교차 테넌트/역할 오류 케이스(`FORBIDDEN`)와 버전 충돌 케이스
      (`CONFLICT`)를 psql로 직접 호출해 확인한다(기존 RPC 검증 방식과 동일,
      `docs/03-processgpt-integration.md` "로컬 검증 기록" 절 참고).
- [x] 6.6 실행 스크립트, 실행 결과, (있다면) 스크린샷을
      `openspec/specs/wms_labor-management/e2e/` 아래에 정리한다.

## 7. 문서/카탈로그 갱신

- [x] 7.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "인력 관리"
      행에 "스펙 완료 → `wms_labor-management`" 비고를 추가한다.
- [ ] 7.2 이 변경이 archive될 때 `openspec/specs/wms_labor-management/spec.md`로
      동기화되는지 확인한다(`openspec archive` 절차). — archive 시점 작업이라
      구현 단계에서는 열어 둔다. 현재 `openspec/specs/wms_labor-management/`에는
      `e2e/`와 `docs/`만 있고 `spec.md`는 archive가 만든다(앞선 7개 영역과 동일).
- [x] 7.3 (연기) 5.2에서 참고 구현 1개만 추가한 나머지 기존 도구
      (`register_arrival`, `receive`, `inspect`, `apply_disposition`,
      `create_putaway_tasks`) 각각에 대한 시작/완료 계측 래퍼 통합은 이
      변경 이후 별도 작업으로 남긴다.

## 8. 프론트엔드 (범위 변경 — 구현에 포함됨)

> proposal.md/design.md는 화면을 "확장 지점"으로 남겼고 이 절도 원래 "연기"였다.
> 구현 지시로 범위에 다시 들어왔다. 앞선 7개 영역이 모두 화면 + Playwright E2E +
> DOCX 매뉴얼까지 갖추고 있어, 이 영역만 계약과 psql 검증에서 멈추면 데모 앱의
> 일관성이 깨지고 프라이버시 규칙이 "화면에서도 지켜지는가"를 보일 방법이 없다.
> 라우트는 design.md가 적은 `/labor/productivity` + `/labor/leaderboard` 두 개
> 대신 `/labor` 한 개로 합쳤다 — 생산성과 리더보드는 같은 기간 선택을 공유하고
> 같은 프라이버시 스코프 배지를 달기 때문에, 나누면 같은 컨트롤이 두 벌 생긴다.

- [x] 8.1 `frontend/src/views/LaborView.vue`를 추가한다 — 작업 시작 폼,
      진행 중 작업 목록(테이블 직접 조회로 RLS 동작을 화면에서 보이게),
      완료(수량 입력)·취소 버튼, 생산성 집계 + 리더보드(응답의 `scope`를
      배지로 노출), 관리자 전용 인력 수요 추정 패널.
- [x] 8.2 `frontend/src/router/index.ts`에 `/labor` 라우트를,
      `frontend/src/App.vue` 사이드내비 WMS 그룹에 `Labor` 링크를 추가한다.
- [x] 8.3 `frontend/playwright/e2e/labor-flow.spec.ts`를 추가한다
      (`LABOR-E2E-*` 픽스처 네임스페이스, `afterAll` 정리). 테스트 2개:
      작업자의 시작→완료→취소→본인 생산성 확인, 관리자의 리더보드 순위 +
      수요 추정 + 감사 이벤트 확인. 전체 스위트 17/17 통과.
- [x] 8.4 `openspec/specs/wms_labor-management/docs/build_manual.mjs`로
      Playwright 스크린샷 8장을 엮은 DOCX 운영자 매뉴얼을 생성한다.
