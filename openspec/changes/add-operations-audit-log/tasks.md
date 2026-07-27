## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

이 계약은 `wms.audit_events`에 어떤 컬럼도 추가하지 않는다(design.md D3 —
`add-agentic-operations`가 소유하는 `wms.agent_decisions`와 경쟁하지 않기로
결정). 따라서 이 절의 마이그레이션은 신규 함수/RPC만 포함한다.

- [x] 1.1 `supabase/migrations/20260806_operations_audit_log.sql`에
      `wms.describe_audit_event(p_command text, p_entity_type text,
      p_before jsonb, p_after jsonb, p_reasoning text default null) returns
      text`를 `language sql immutable`로 구현했다. 전용 `CASE` 분기는
      tasks.md가 요구한 core 8개를 넘어 **실제로 쓰이는 65개 command 전부**를
      덮고(같은 파일 헤더의 grep이 그 65를 센다), 여기에 이 계약 자신의
      `wms_export_audit_log`를 더해 66개 분기 + 범용 폴백이다. 4개의 작은
      IMMUTABLE 헬퍼(`_audit_val`/`_audit_txt`/`_audit_opt`/`_audit_chg`)와
      엔티티 한국어 명칭 맵(`_audit_entity_ko`)이 템플릿을 문장처럼 읽히게
      한다. `verify.sql` §B1이 65/65를 세고, §B1b가 폴백으로 떨어진 명령
      목록이 0행임을 확인하며, §B2~§B8이 "감사 이벤트의 결정론적 한국어 요약"
      과 "에이전트 판단 근거의 요약 반영" Requirement의 모든 시나리오를 검증한다.

## 2. 조회/내보내기 RPC (1단계 — core schema만 의존, `add-agentic-operations`
와 무관하게 즉시 구현 가능)

- [x] 2.1 `wms.wms_query_audit_log` 구현. `p_tenant_id` 필수 + 7개 선택 필터 +
      `p_limit`(기본 50, 1~500 범위 밖은 `INVALID`)/`p_offset`, 역할 검사는
      공유 헬퍼 `wms._audit_require_reader`로 분리했다. **`count(*) over()`
      대신 별도 `count(*)`**를 쓴다 — 윈도우 함수는 마지막 페이지를 넘어가면
      행이 없어 총계까지 사라지고, 총계를 잃는 페이저는 없는 것만 못하다
      (`verify.sql` §E4가 offset 500에서 `total_count=120`이 살아 있음을
      확인). "감사 로그 조회" Requirement의 시나리오 전부 검증(§C, §D, §E, §F).
- [x] 2.2 `wms.wms_export_audit_log` 구현. 조회와 **완전히 같은 순서의 같은
      8개 필터**(design.md는 export에서 `p_entity_id`를 빠뜨렸으나 두 표면의
      파라미터 순서를 다르게 두는 것은 위치 인자 호출자에게 함정이므로 맞췄다
      — V1), 페이지네이션 없음, 상한 초과 시 `INVALID:`. 검증 §H1/§H5/§H6.
- [x] 2.3 성공 시 `command='wms_export_audit_log'`,
      `entity_type='audit_export'`, `after`에 사용된 필터 + `exported_row_count`
      를 담은 자기 감사 행을 INSERT한다. 결과 집합을 확정한 **뒤에** 기록하므로
      내보내기가 자기 자신을 포함하지 않고(§H2), 다음 조회에서 보인다(§H3).
      actor는 `auth.uid()`다 — `p_actor_id`는 actor **필터**로 이미 쓰이고 있어
      그것을 재사용하면 감사 기록을 위조하는 셈이 된다(V4, §H4).
- [x] 2.4 두 RPC + `describe_audit_event` + 5개 헬퍼에 `grant execute ... to
      authenticated` 부여(역할 검사는 함수 내부). 내부 가드 2개
      (`_audit_require_reader`, `_audit_validate_filters`)는 기존 `_wms_*`
      관례대로 미부여.
- [x] 2.5 `audit_events_select` RLS 정책이 이 마이그레이션에서 수정되지
      않았음을 확인했다 — 파일에 `alter policy`/`drop policy`/`alter table
      wms.audit_events`가 하나도 없고, `verify.sql` §A가 정책 본문을 그대로
      출력해 보여 준다. §G는 한 걸음 더 나가, §F1에서 RPC 호출을 거절당한 바로
      그 `INBOUND_OPERATOR` 사용자가 `set local role authenticated` 상태로
      원본 테이블을 직접 SELECT해 자기 테넌트 행을 정상적으로 읽고, 다른
      테넌트 행은 0건인 것까지 확인한다. "원본 테이블 직접 열람 권한은 그대로
      유지된다" 시나리오 검증.
- [x] 2.6 `INBOUND_OPERATOR`/`QUALITY_INSPECTOR`/`PROCUREMENT_BUYER`/
      `PROCESS_AGENT` 4개 역할 × 2개 RPC = 8회 호출 전부 `FORBIDDEN:` 확인
      (§F1, §F2). 교차 테넌트도 같은 `FORBIDDEN`이다 — `has_role`이 멤버십
      스코프라 테넌트 검사가 곧 역할 검사가 된다(§F3). "권한이 없는 역할은
      감사 로그를 조회할 수 없다", "권한이 없는 사용자는 내보내기를 요청할 수
      없다", "같은 사용자가 조회/내보내기 RPC는 호출할 수 없다", "다른 테넌트의
      감사 이벤트는 조회되지 않는다" 시나리오 검증.

## 2b. 판단 근거 조인 (2단계 — `add-agentic-operations`의 `wms.agent_decisions`
마이그레이션이 적용된 뒤에만 착수)

- [x] 2b.1 확인 완료 — `wms.agent_decisions`는
      `supabase/migrations/20260805_agentic_operations.sql` 246행에 실재하고,
      `reasoning text not null`(263행)과 `correlation_id text`(275행) 모두
      design.md D3가 가정한 형태 그대로다. 마이그레이션 상단의 `do $$ ... $$`
      가드 블록이 `to_regclass('wms.agent_decisions') is null`이면 설치를
      중단시켜, 이 확인을 주석이 아니라 실행 시점 제약으로 만든다.
- [x] 2b.2 2단계 조인 구현. **다만 1단계 정의 후 즉시 `create or replace`로
      덮어쓰는 대신, 두 함수를 조인이 들어간 형태로 한 번만 정의했다**(V2) —
      area 10이 먼저 구현된 상태에서 같은 150줄을 두 번 쓰는 것은 리뷰어에게
      설명할 수 없는 중복이기 때문이다. 조인은 각 함수의
      `left join lateral (...) ad on true` 블록 하나에 갇혀 있고, 그 블록을
      지우고 `ad.reasoning`을 `null::text`로 바꾸면 시그니처·반환 형태 변경
      없이 1단계로 되돌아간다. 평범한 `LEFT JOIN`이 아니라 lateral + `limit 1`
      인 이유는 `correlation_id`가 유일하지 않아서다 — 한 프로세스 인스턴스에
      판단 기록이 둘 쌓이면 감사 이벤트가 두 번 나오고 `total_count`와
      어긋난다(V3, §I3이 그 상황을 만들어 1행만 나오는 것을 확인). 조인은
      `d.tenant_id = e.tenant_id`로도 스코프된다(§I5). "판단 근거가 있는
      에이전트 실행 이벤트를 요약한다", "판단 근거가 연결된 이벤트는 조회
      결과에 그대로 노출된다" 시나리오 검증.
- [x] 2b.3 매칭되는 판단 기록이 없는 이벤트(사람이 수행한 대부분)가 여전히
      정상 요약되는지 회귀 검증(§I4 — `has_reasoning=false`, 근거 문구 없는
      정상 문장 3건). "사람이 수행한 명령은 판단 근거 없이 요약된다", "판단
      근거 계약이 아직 없어도 감사 이벤트는 정상적으로 기록·조회된다" 시나리오
      검증.

## 3. 시드 데이터 / 로컬 검증

- [x] 3.1 `supabase/seed.sql`에 `auditor-a@demo.local`(`Demo1234!`)을 추가하고
      테넌트 A `AUDITOR` 멤버십 + 창고 스코프를 부여했다. 확인 결과 기존 시드에
      `AUDITOR` 멤버십은 한 건도 없었다(스키마 30행 주석에만 존재). 이 역할은
      저장소 어디에도 쓰기 권한이 없다 — 기록을 고칠 수 있는 감사자는 감사자가
      아니다.
- [x] 3.2 실제 데모 흐름(RFQ → 승인 → PO 확정)을 psql로 한 차례 돌려 쌓인
      감사 이벤트로 `wms_query_audit_log`를 호출하고, 생성된 한국어 문장을
      육안 검토했다(§C1). UI 쪽에서는 Playwright가 Dock Schedule 화면에서
      도크를 등록하고 정비 마감한 뒤, 감사 화면에서
      `도크 AUDIT-E2E-DOCK-01(...)가 등록되었다`와
      `도크 ...의 상태가 변경되었다 — AVAILABLE → CLOSED`를 문자열로 대조한다.
- [x] 3.3 에이전트가 **실제로 허용된 RPC**(`wms_create_rfq`)를 PROCESS_AGENT로
      호출하고 같은 `correlation_id`로 `wms_log_agent_decision`을 남긴 뒤,
      그 근거가 요약과 조회 결과에 함께 나오는 것을 확인했다(§I1/§I2 + E2E
      테스트 1의 스크린샷 04). 직접 INSERT가 아니라 진짜 RPC 왕복이다.
- [x] 3.4 **상한 값을 임시로 낮췄다 되돌리는 방식은 쓰지 않았다.** 그것은
      출시되지 않는 코드를 검증하는 것이므로, 대신 `p_max_rows`를 기본
      10,000 · 하드 실링 10,000의 파라미터로 만들어 낮추기만 가능하게 했다
      (V5). `p_max_rows => 3`으로 `INVALID:` 분기를 출시되는 코드 그대로
      검증하고(§H5), 거절된 호출이 자기 감사 행조차 남기지 않는 것과
      `p_max_rows => 20000`이 거부되는 것도 함께 확인했다(§H5, §H6). "안전
      상한을 초과하는 내보내기는 거부된다" 시나리오 검증.

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`) — 후속 구현

- [x] 4.1 `query_audit_log`, `export_audit_log` 추가(총 84개 도구). 두 도구
      모두 `PROCESS_AGENT` 허용 목록에서 제외했다. 나아가 이 둘은 서버에서
      유일하게 **세 번째 서비스 아이덴티티**(`WMS_AUDITOR_EMAIL`,
      `client.get_auditor_client()`)로 로그인한다 — PROCESS_AGENT 자격증명으로는
      RPC가 `FORBIDDEN`을 돌려주므로 아이덴티티 분리는 편의가 아니라 유일하게
      동작하는 구성이다. `config.py`, `client.py`, `.env`, `.env.example`에
      대응 항목을 추가했다.
- [x] 4.2 `docs/03-processgpt-integration.md`의 허용 목록 코드블록에 두 도구를
      주석 처리해 명시하고, "note (자연어 감사 로그)" 절을 추가해 **열한 개
      영역 중 신규 도구가 전부 제외된 유일한 계약**인 이유를 적었다.

## 5. E2E 검증 (`openspec/specs/wms_operations-audit-log/e2e/`에 응집)

- [x] 5.1 happy path 왕복 검증(§C): RFQ 생성 → 승인 → PO 확정 → 감사 이벤트
      3건 → `wms_query_audit_log`로 조회 → 한국어 요약 육안 확인.
- [x] 5.2 내보내기 → 자기 감사 → 재조회 흐름 확인(§H1~§H4). E2E 테스트 1은
      브라우저에서 CSV를 실제로 내려받아(blob 다운로드) 헤더 + 30행과 한국어
      요약이 들어 있는 것을 파일 내용으로 확인하고, 내보내기 전후로
      `wms_export_audit_log` 감사 이벤트가 정확히 1건 늘어나는 것을 psql로
      대조한 뒤, 화면에서 그 행을
      `감사 로그 30건이 내보내졌다`로 다시 읽는다.
- [x] 5.3 교차 테넌트/역할 오류 케이스를 psql로 직접 호출해 확인(§F). E2E
      테스트 2는 같은 경계를 UI 쪽에서 세 겹으로 확인한다 — nav 링크 미노출 /
      URL 직접 입력 시 리다이렉트 / 브라우저를 건너뛴 RPC 직접 호출도
      `FORBIDDEN`. 앞의 둘은 예의고 마지막 하나가 통제라는 점을 테스트가
      그 순서로 드러낸다.
- [x] 5.4 `openspec/specs/wms_operations-audit-log/e2e/`에 `verify.sql`,
      `verify-run.txt`, `playwright-run.txt`(전체 23개 통과), `screenshots/`
      7장, `README.md`를 정리했다.

## 6. 문서/카탈로그 갱신

- [x] 6.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 "자연어 Audit Log"
      행에 스펙 완료 표기가 이미 있었고, 여기에 **구현 완료** 사실(마이그레이션
      파일, 화면 경로, MCP 도구 2종, 템플릿 커버리지 65/65, 검증 기록 위치)을
      덧붙였다.
- [x] 6.2 archive 시 `openspec/specs/wms_operations-audit-log/spec.md`로
      동기화되도록 delta spec을 그대로 두었다. `e2e/`와 `docs/`는 다른 열 개
      영역과 같은 레이아웃으로 이미 그 경로 아래에 만들어져 있다.
- [x] 6.3 `add-agentic-operations`의 최종 스키마를 실제 마이그레이션에서 확인:
      `reasoning`, `correlation_id` 모두 design.md D3의 가정과 일치해 조인
      쿼리를 고칠 필요가 없었다(2b.1). 인덱스도 area 10이 이미
      `agent_decisions_correlation_idx`를 갖고 있어 이 계약은
      `wms.agent_decisions`에 아무것도 추가하지 않는다 — 읽기만 한다.

## 7. 프론트엔드

원 계획은 이 절을 "연기"로 두었으나, 열한 개 영역 중 화면 없는 계약이 하나만
남는 것은 데모 앱으로서 일관되지 않아 이번 변경에 포함해 구현했다.

- [x] 7.1 `frontend/src/views/AuditLogView.vue` + 라우트
      `/operations/audit-log`(`meta.roles`) + `App.vue`의 새 **OVERSIGHT** nav
      그룹. 필터 폼(기간·행위자·엔티티 종류·명령·상관관계 ID) + 20건 단위
      페이지네이션 + CSV 다운로드 버튼. 행위자/엔티티/명령 드롭다운은 하드코딩
      목록이 아니라 조회 RPC가 함께 돌려주는 `facets`로 채운다 — 65개 명령
      이름을 프론트엔드에 복사해 두면 열두 번째 영역에서 바로 썩는다(V6).
      판단 근거가 붙은 행에는 노란 상자로 원문을 함께 보여 준다. CSV는 BOM을
      붙여 내보낸다(BOM 없는 UTF-8은 Windows 엑셀이 cp949로 읽어, 이 계약이
      대상으로 삼는 재무 담당자에게 정확히 깨져 보인다).
- [x] 7.2 DOCX 감사자 매뉴얼
      `openspec/specs/wms_operations-audit-log/docs/operations-audit-log-auditor-manual.docx`
      (1.4MB, 스크린샷 7장 전부 실제 Playwright 프레임)와 재생성 스크립트
      `build_manual.mjs`.
