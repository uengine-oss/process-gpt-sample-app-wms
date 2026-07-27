## 0. 선행 조건 확인

- [x] 0.1 `add-wcs-equipment-control-contract`(area1, capability
      `wms_wcs-equipment-control`)의 마이그레이션이 대상 데이터베이스에 이미
      적용되어 있는지 확인한다. 적용되어 있지 않다면 그 변경의 tasks.md를
      먼저 완료한다 — 이 변경의 모든 DB 작업은 `wms.equipment`,
      `wms.equipment_commands`, `wms_dispatch_equipment_command`,
      `wms_report_command_result`, `WCS_GATEWAY` 역할이 존재함을 전제로
      한다(design.md "정직한 전제 확인" 참고).
- [x] 0.2 이 변경은 area2~5(`wms_wes-material-flow-control`,
      `wms_wcs-sortation-logic`, `wms_wcs-bottleneck-routing`,
      `wms_wcs-sequential-dispatch`)에 스키마 의존성이 없음을 재확인한다
      (design.md D8) — 그 스펙들이 구현되어 있지 않아도 이 변경의 마이그레이션과
      RPC는 area1만으로 적용·검증 가능해야 한다.
- [x] 0.3 `WCS_GATEWAY` 역할을 가진 시드 계정(이 변경의 워커 프로세스가
      로그인에 사용)이 시드 데이터에 준비되어 있는지 확인한다. 없다면
      area1의 시드 데이터 준비 작업을 참고해 이 변경의 tasks.md 5장에서
      추가한다.

## 1. 스키마 마이그레이션 (신규 파일, 기존 마이그레이션 미변경)

- [x] 1.1 `supabase/migrations/`에 새 마이그레이션 파일(예:
      `<timestamp>_wms_wcs_digital_twin_simulation.sql`)을 추가하고
      `wms.simulation_profiles`, `wms.simulation_command_schedules`,
      `wms.simulation_scenarios`, `wms.simulation_scenario_runs` 테이블을
      design.md 데이터 모델대로 생성한다. 파일 이름의 타임스탬프는 area1의
      마이그레이션보다 뒤여야 한다. "시뮬레이션 프로파일 등록과 갱신",
      "시뮬레이션 명령 계획 수립", "what-if 시나리오 정의" Requirement 검증.
- [x] 1.2 `wms.equipment`(area1 소유)에 `is_simulated boolean not null
      default false` 컬럼을 추가하는 `alter table` 문을 같은 마이그레이션
      파일에 포함한다. 원 테이블 정의(area1의 마이그레이션 파일)는 수정하지
      않는다. "설비 시뮬레이션 모드 지정" Requirement 검증.
- [x] 1.3 각 테이블의 `status`/`command_status` 계열 컬럼에 `CHECK` 제약을
      추가해 스펙에 정의된 값 집합만 허용되게 하고, `unique
      (equipment_id)`(프로파일), `unique (command_id)`(진행 계획) 제약을
      추가한다.

## 2. RLS 정책

- [x] 2.1 신규 4개 테이블에 `enable row level security`를 적용하고, 기존
      테이블과 동일한 패턴(`warehouse_id in (select
      wms.current_warehouse_ids(tenant_id))`)의 `select` 정책만 추가한다.
      "테넌트·창고 단위 접근 통제" Requirement 검증.
- [x] 2.2 `authenticated`/`anon`에 네 테이블의 `insert`/`update`/`delete`
      권한을 부여하지 않았는지 확인하는 psql 점검 스크립트를 작성한다.
- [x] 2.3 교차 테넌트 접근 차단을 psql로 직접 검증한다(테넌트 A의
      `WCS_GATEWAY` 계정이 테넌트 B 소유 명령의 계획을 수립할 수 없음). "다른
      테넌트의 시뮬레이션 프로파일에는 접근할 수 없다" 시나리오 검증.

## 3. Command RPC

- [x] 3.1 `wms.wms_set_equipment_simulation_mode`를 구현한다 — 역할 검사
      (`WMS_ADMIN`, `WAREHOUSE_MANAGER`), `expected_version` 기반 낙관적
      동시성, `wms.equipment`의 다른 컬럼(특히 `status`)은 건드리지 않는지
      확인. "설비 시뮬레이션 모드 지정" Requirement의 2개 시나리오 전부 검증.
- [x] 3.2 `wms.wms_register_simulation_profile`, `wms.wms_update_simulation_profile`을
      구현한다 — 대상 설비 `is_simulated=true` 검증, 중복 등록 거부,
      `wms.idempotency_records` 연동, `wms.audit_events` 기록. "시뮬레이션
      프로파일 등록과 갱신" Requirement의 4개 시나리오 전부 검증.
- [x] 3.3 `wms.wms_get_simulation_profile`을 구현한다 — 등록된 프로파일이
      없거나 `INACTIVE`면 design.md D4의 시스템 기본값(코드 내장 상수)으로
      대체해 반환하고, 그 값이 기본값임을 표시하는 필드를 포함한다.
      "시뮬레이션 프로파일 조회와 기본값 대체" Requirement의 2개 시나리오
      전부 검증.
- [x] 3.4 `wms.wms_plan_simulated_command`를 구현한다 — 대상 설비
      `is_simulated=true` 검증, 기존 계획 존재 시 멱등 반환, 프로파일(또는
      기본값)의 확률로 `random()` 기반 지연·최종 결과 산출, `command_type`
      별 결과 payload 어휘 매핑(design.md D5 — `DIVERT`→area3 어휘,
      `PALLETIZE`→area5 어휘, 그 외→일반 어휘). "시뮬레이션 명령 계획 수립",
      "명령 타입별 결과 payload 어휘 매핑" Requirement의 시나리오 전부 검증.
- [x] 3.5 `wms.wms_get_due_simulation_actions`를 구현한다 — `next_run_at
      <= p_as_of` 필터, `next_run_at` 오름차순 정렬. "대기 중인 시뮬레이션
      액션 조회", "시뮬레이션 대상이 아닌 설비의 배제" Requirement의 시나리오
      전부 검증.
- [x] 3.6 `wms.wms_advance_simulated_command`를 구현한다 — 계획 존재·도래
      여부 검증, 내부적으로 area1의 `wms_report_command_result` 호출(같은
      호출자 신원으로), 중간 단계면 계획 갱신, 종결 단계면 계획 삭제.
      "시뮬레이션 명령 진행 보고" Requirement의 3개 시나리오 전부 검증.
- [x] 3.7 `wms.wms_get_simulation_schedule_status`를 구현한다 — 읽기 전용
      조인 조회, `p_due_only` 필터 지원.
- [x] 3.8 `wms.wms_create_simulation_scenario`를 구현한다 — 설비 집합
      비어있음/명령 건수 0 이하 검증, 대상 설비 존재 확인. "what-if 시나리오
      정의" Requirement의 3개 시나리오 전부 검증.
- [x] 3.9 `wms.wms_run_simulation_scenario`를 구현한다 — 실제 명령 디스패치
      없이 설비별 프로파일(또는 기본값)로 `projected_completion_at`,
      `projected_round_count`, `projected_failure_count` 산출(design.md D7
      산술 모델), 기본값 적용 설비가 있으면 `warnings`에 포함, 매 실행마다
      새 `wms.simulation_scenario_runs` 행 생성. "시나리오 실행과 예상
      타임라인 산출" Requirement의 3개 시나리오 전부 검증.
- [x] 3.10 `wms.wms_get_simulation_scenario_status`를 구현한다 — 읽기 전용
      조인 조회.
- [x] 3.11 9개 쓰기 RPC 전부에 대해 `grant execute ... to authenticated`를
      추가한다.
- [x] 3.12 감사 이벤트 커버리지를 psql로 점검한다 — 시뮬레이션 모드 지정,
      프로파일 등록/갱신, 시나리오 정의/실행 각각에 대해 `wms.audit_events`에
      올바른 `command`/`entity_type`/`before`/`after`가 기록되는지 확인.
      "감사 추적" Requirement의 2개 시나리오 검증.
- [x] 3.13 멱등성 재시도 테스트: 동일 `idempotency_key`로
      `wms_register_simulation_profile`을 2회 호출해 레코드가 1건만
      생성되는지 확인한다.

## 4. MCP 도구 노출 (`mcp/wms_mcp/mcp_server.py`)

- [x] 4.1 기존 `@mcp.tool` 패턴을 따라 아래 도구를 추가한다:
      `set_equipment_simulation_mode`, `register_simulation_profile`,
      `update_simulation_profile`, `get_simulation_profile`,
      `plan_simulated_command`, `get_due_simulation_actions`,
      `advance_simulated_command`, `get_simulation_schedule_status`,
      `create_simulation_scenario`, `run_simulation_scenario`,
      `get_simulation_scenario_status`.
- [x] 4.2 각 쓰기 도구 반환값에 `next_actions`를 채운다(예:
      `create_simulation_scenario` → `["run_simulation_scenario"]`,
      `register_simulation_profile` → `["set_equipment_simulation_mode"]`).
- [x] 4.3 `docs/03-processgpt-integration.md`의 에이전트 tool 허용 목록
      표에 `PROCESS_AGENT`가 호출 가능한 도구(시나리오 정의·실행) 목록을
      추가한다 — 명령 계획·진행 보고 도구는 `WCS_GATEWAY` 전용이므로
      `PROCESS_AGENT` 허용 목록에 넣지 않는다.

## 5. 외부 워커 프로세스 (`mcp/wms_mcp/simulator/`)

- [x] 5.1 `mcp/wms_mcp/simulator/wcs_gateway_simulator.py`(후보 경로)를
      작성한다 — `WCS_GATEWAY` 시드 계정으로 Supabase Auth 로그인, 고정
      주기(예: 1~2초) 폴링 루프, design.md "외부 워커 프로세스" 절의 5단계
      로직(신규 `PENDING` 명령 탐지 → 계획 수립 → 도래 액션 조회 → 진행
      보고 → 오류 재시도) 구현.
- [x] 5.2 워커 실행 방법(환경 변수, 실행 명령)을 이 변경의 `e2e/` 문서에
      기록한다 — `docs/02-contracts.md` 스타일의 "Dockerized infrastructure
      + source-run application services" 원칙에 따라 소스에서 직접 실행하는
      명령으로 문서화한다(새 Docker 이미지를 만들지 않는다).
- [x] 5.3 워커가 중간에 중단되었다가 재시작되어도 진행 중이던 계획이
      유실되지 않고 이어서 진행되는지 확인하는 재시작 안전성 테스트를
      작성한다(design.md D3 검증).

## 6. E2E 검증 (`openspec/specs/wms_wcs-digital-twin-simulation/e2e/`에 응집)

- [x] 6.1 area1의 시뮬레이션 대상 설비 1대를 시드하고, 명령 디스패치 →
      워커의 자동 계획 수립·진행 보고 → `COMPLETED` 반영까지의 happy path를
      왕복 검증한다.
- [x] 6.2 `failure_rate=1`인 프로파일로 항상 `FAILED`가 보고되는 경로를
      검증하고, `command_type='DIVERT'`에서 `jam_rate=1`이면 항상 `JAM`
      outcome(및 area3가 구현되어 있다면 자동 장애 승격까지)이 재현되는지
      확인한다.
- [x] 6.3 `command_type='PALLETIZE'`(area5가 구현되어 있는 경우)에 대해
      계획된 `loaded_items` 배열이 실제 `wms_report_command_result` 호출을
      거쳐 area5의 항목 단위 완료 전파까지 이어지는지 왕복 검증한다 — area5가
      구현되어 있지 않으면 이 케이스는 건너뛰고 문서에 남긴다.
- [x] 6.4 `is_simulated=false`인 설비의 명령이 대기 액션 조회에 포함되지
      않고, 자동으로 진행되지 않는지 확인한다.
- [x] 6.5 시나리오 정의 → 실행 → 예상 완료 시점/실패 건수 산출까지, 어떤
      `wms.equipment_commands` 레코드도 새로 생성되지 않는지 왕복 검증한다.
- [x] 6.6 워커 프로세스를 의도적으로 중지했다가 재기동해 5.3의 재시작
      안전성이 실제 E2E 경로에서도 유지되는지 확인한다.
- [x] 6.7 교차 테넌트/역할 오류 케이스(`FORBIDDEN`)와 버전 충돌 케이스
      (`CONFLICT`)를 psql로 직접 호출해 확인한다.
- [x] 6.8 워커 스크립트 실행 로그, 시나리오 실행 결과 샘플을
      `openspec/specs/wms_wcs-digital-twin-simulation/e2e/` 아래에 정리한다.

## 7. 문서/카탈로그 갱신

- [x] 7.1 `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "디지털
      트윈/시뮬레이션" 행에 "스펙 완료 → `wms_wcs-digital-twin-simulation`"
      비고를 추가한다(이미 이 변경과 함께 완료됨 — 회귀 확인용 항목).
- [ ] 7.2 이 변경이 archive될 때
      `openspec/specs/wms_wcs-digital-twin-simulation/spec.md`로 동기화되는지
      확인한다(`openspec archive` 절차).
      **미완료 — archive를 아직 실행하지 않았다.** `openspec/specs/
      wms_wcs-digital-twin-simulation/` 아래에는 현재 `e2e/`와 `docs/` 산출물만
      있고 `spec.md`는 없다(선행 5개 area와 동일한 상태). archive 시점에
      동기화된다.
- [x] 7.3 design.md Risks가 남긴 미해결 통합 지점(시나리오의
      `p_command_count` 수동 전달, 결정론적 재현 부재)이 §5 표와 다시
      대조되어 있는지 확인한다.

## 8. 프론트엔드 (이번 변경 범위 아님 — 후속 작업 메모만)

- [x] 8.1 ~~(연기)~~ `frontend/src/router/index.ts`에 `/wcs/simulation`,
      `/wcs/scenario-planner` 라우트와 대응 뷰 컴포넌트를 추가하는 작업은
      이 변경에 포함하지 않는다 — design.md "프론트엔드 확장 지점" 절의
      위치만 따르는 후속 변경으로 남긴다.
      **계획 변경(범위 확대) — 결국 이 변경에서 함께 구현했다.**
      선행 5개 area가 모두 화면 + Playwright E2E까지 한 변경에 담았고, 이
      area의 핵심 주장("시뮬레이션 설비도 일반 화면에서 똑같이 보인다")은
      UI 없이는 증명할 방법이 없다. 구현 범위:
      `frontend/src/views/WcsSimulationView.vue`(모드 전환 · 프로파일 ·
      진행 중인 계획 · what-if 시나리오를 한 화면에 담음), 라우트
      `/wcs/simulation`, `App.vue` 내비게이션 항목.
      `/wcs/scenario-planner`는 **만들지 않았다** — 시나리오 카드가
      같은 화면 안에 들어가 별도 라우트가 불필요했다.

## 검증 기록 (체크 근거)

모든 산출물은 `openspec/specs/wms_wcs-digital-twin-simulation/` 아래에 있다.
자세한 설명·일탈 사항·남은 한계는 그 아래 `e2e/README.md` 참고.

| 항목 | 근거 |
|---|---|
| 마이그레이션 체인 | `supabase db reset` 7개 파일 전부 정상 적용 |
| 3장 RPC 계약 (전 요구사항) | `e2e/simulator.sql` → `e2e/simulator-run.txt` |
| 4장 MCP 도구 11종 | `e2e/mcp_roundtrip.py` → `e2e/mcp_roundtrip-run.txt` (서버 총 49개 도구) |
| 5장·6장 **외부 워커 실행** | `e2e/worker_e2e.sh` → `e2e/worker-run.txt` (8단계) |
| 6.1 happy path | worker-run STEP 1~3 — `--once` 한 번에 `PENDING→…→COMPLETED` |
| 6.2 실패/잼 주입 | worker-run STEP 3 — `jam_rate=1` DIVERT가 `JAM`으로 끝나고 area 3의 `SORTATION_JAM`/CRITICAL 장애로 자동 승격 |
| 6.3 PALLETIZE 항목 단위 전파 | worker-run STEP 7~8 — 워커의 보고 1건이 서열 2건·출고 단위 2건을 모두 `COMPLETED`로 전파 |
| 6.4 비대상 설비 배제 | worker-run STEP 3 — `WRK-REAL`은 끝까지 `PENDING` |
| 6.5 시나리오 dry-run | `simulator-run.txt` §6 + Playwright 2번 테스트 (명령 건수 전후 동일) |
| 5.3 / 6.6 재시작 안전성 | worker-run STEP 4~6 — **별도 프로세스 4개**로 진행, ack/progress/terminal 각 1회 |
| 6.7 FORBIDDEN / CONFLICT | `simulator-run.txt` §1·§2·§7 |
| 브라우저 E2E | `frontend/playwright/e2e/wcs-simulation-flow.spec.ts` 2개 → 전체 스위트 13/13 통과 (`e2e/playwright-run.txt`) |
| 운영자 매뉴얼 | `docs/build_manual.mjs` → `docs/wcs-digital-twin-simulation-operator-manual.docx` (스크린샷 14장) |

### 연기한 것

- **7.2 archive 동기화** — 아직 `openspec archive`를 실행하지 않았다.
- **결정론적 재현** — design.md Non-Goal 그대로 남긴다(시드 없는 `random()`).
  단, 명령 하나의 결과는 계획 시점에 고정되므로 재시작 안전성에는 영향 없다.
- **`--loop` 모드의 캡처된 실행 로그** — 종료되지 않는 모드라 로그로 남기지
  않았다. `--once`/`--tick`과 동일한 tick 함수를 `sleep`으로 반복할 뿐이다.
