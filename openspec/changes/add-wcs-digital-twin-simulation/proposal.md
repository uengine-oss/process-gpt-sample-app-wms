## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.2, §3, §4 Swisslog SynQ)가 정리한
"디지털 트윈/시뮬레이션"은 Swisslog SynQ가 가장 깊게 다루는 영역이다 —
"디지털 트윈 기반의 에뮬레이션 및 시뮬레이션 도구를 탑재하여 사전 검증이
가능하며 ... SAP EWM과의 엔드투엔드 연동 프로세스를 표준으로 지원", "가상
환경 시뮬레이션 기반 운영 최적화". 실제 벤더는 이 기능을 (1) 설비 구매 전
제어 로직을 가상 환경에서 사전 검증하는 에뮬레이션과 (2) 운영 중 "이 조건이면
어떻게 될까"를 묻는 what-if 시뮬레이션 두 축으로 쓴다.

**이 샘플 앱에서 이 영역이 갖는 특별한 위치**: `add-wcs-equipment-control-contract`
(area1)의 D5는 "이 역할은 실제 하드웨어 유무와 무관하게 동작한다 — 데모에서는
소프트웨어 시뮬레이터가 `WCS_GATEWAY`로 인증해 이 계약을 채운다"고 이미 못을
박았고, area1의 확장 지점 표는 이 변경(당시 가칭 `wms_wes-digital-twin`)을
정확히 "`WCS_GATEWAY` 역할로 인증하는 시뮬레이터 자체가 이 계약의 첫
구현체가 된다"고 예견했다. area2~5의 확장 지점 표도 각각 "시뮬레이터가
`wms_report_command_result`를 호출하면 이 계약의 트리거/검증이 그대로
반응한다"고 반복해서 언급했다. 즉 **이 저장소에는 실제 자동화 하드웨어가
전혀 없으므로, area1~5가 정의한 WMS↔WCS 소프트웨어 계약을 실제로 왕복
동작시키는 유일한 방법이 이 변경이 정의하는 시뮬레이터다.** 지금까지 각
변경의 tasks.md가 "area1의 소프트웨어 시뮬레이터 스크립트를 재사용해 왕복
검증한다"고 반복해서 언급해 온 그 스크립트를, 이 변경이 처음으로 정식
계약(등록 가능한 설비별 타이밍/실패율 프로파일, 재시작 안전한 진행 상태,
감사 가능한 RPC)으로 승격시킨다.

**정직한 스코프 확인**: 이 변경은 두 가지를 다루되 무게가 다르다.

1. **시뮬레이터-as-게이트웨이(실질적으로 구현 가능한 핵심)**: `is_simulated=true`로
   표시된 설비에 대해, 디스패치된 명령을 현실적인 상태 전이(`PENDING`→
   `ACKNOWLEDGED`→`IN_PROGRESS`→`COMPLETED`/`FAILED`)로 자동 진행시키는
   계약. 이것이 이 변경의 핵심이며, area1~5의 계약을 실제로 채우는 유일한
   방법이라는 점에서 "사전 검증"이라는 카탈로그 문구도 문자 그대로 만족한다.
2. **시나리오/what-if 프로젝션(더 가벼운, 야심을 낮춘 부분)**: "웨이브 X를
   설비 집합 Y로만 처리하면 어떻게 될까"를 시뮬레이터의 타이밍 모델을 재사용해
   추정하는 dry-run. **명시적으로 축소한다**: 실제 명령을 디스패치하지 않는
   순수 산술 추정(예상 완료 소요시간)일 뿐, 3D 모션·물리 시뮬레이션이 아니다.
   그런 진짜 디지털 트윈은 이 샘플 앱(그린필드 WMS 소프트웨어 데모)의 범위를
   한참 넘는다 — 이 변경은 그 사실을 design.md에 정직하게 남긴다.

## What Changes

- `wms` 스키마(기존과 동일 schema/인스턴스, 동일 RLS/RPC 봉투 규약)에 신규
  테이블 4종을 추가한다: 설비별 시뮬레이션 타이밍/실패율 프로파일
  (`wms.simulation_profiles`), 명령별 진행 계획(`wms.simulation_command_schedules`),
  what-if 시나리오 정의(`wms.simulation_scenarios`), 시나리오 실행 결과
  (`wms.simulation_scenario_runs`). 신규 서비스나 신규 데이터베이스를 만들지
  않는다.
- `wms_wcs-equipment-control`(area1)이 소유한 `wms.equipment`에 새 컬럼
  `is_simulated boolean`을 추가하는 마이그레이션을 얹는다 — 그 테이블의 원
  마이그레이션 파일 자체는 수정하지 않는다(area3/area5가 `command_type`
  `CHECK` 제약을 확장한 것과 동일한 원칙).
- 기존 RPC와 동일한 봉투(`tenant_id, warehouse_id, actor_id, idempotency_key,
  expected_version, correlation_id` 입력 / `{result, document_id, status,
  version, next_actions, warnings}` 출력, `CONFLICT:`/`FORBIDDEN:`/`INVALID:`
  접두 예외)를 따르는 새 RPC 10종을 추가한다: 설비 시뮬레이션 모드 지정,
  프로파일 등록·갱신·조회, 시뮬레이션 명령 계획 수립, 대기 중 액션 조회,
  시뮬레이션 명령 진행 보고, 시나리오 정의·실행·조회.
- `mcp/wms_mcp/mcp_server.py`에 위 RPC를 감싸는 새 `@mcp.tool` 함수를
  추가한다.
- **외부 워커 프로세스**(예: `mcp/wms_mcp/simulator/wcs_gateway_simulator.py`
  후보 위치)를 새로 정의한다 — `WCS_GATEWAY` 서비스 아이덴티티로 Supabase에
  인증해 위 RPC를 호출하는 폴링 루프 스크립트. 새 마이크로서비스가 아니라
  `mcp_server.py`처럼 소스에서 직접 실행하는 로컬 프로세스다. 이 선택의 근거는
  design.md D2에 상세히 남긴다(핵심 이유: `WCS_GATEWAY` 인증에는 Supabase
  Auth 세션(`auth.uid()`)이 필요한데, Postgres 스케줄 함수(pg_cron 등)에는
  그 세션이 없다).
- 새 service role은 추가하지 않는다 — area1이 이미 도입한 `WCS_GATEWAY`를
  시뮬레이터의 인증 아이덴티티로 그대로 재사용한다.
- 실제 3D 모션/물리 시뮬레이션 엔진, PLC/필드버스 프로토콜, ML 기반 최적
  시나리오 탐색은 이번 변경에 포함하지 않는다(design.md Non-Goals).
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "디지털 트윈/시뮬레이션"
  행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_wcs-digital-twin-simulation`: `is_simulated=true`로 표시된 설비에 대해
  실제 하드웨어 없이 area1의 명령 디스패치 계약을 현실적인 타이밍·실패/잼
  주입률로 자동 이행하는 소프트웨어 시뮬레이터 계약(설비별 프로파일, 재시작
  안전한 진행 계획, `WCS_GATEWAY` 인증 워커 프로세스)과, 그 타이밍 모델을
  재사용해 설비 구성 변경의 예상 완료 시점을 추정하는 제한적 범위의 what-if
  시나리오 dry-run 계약.

### Modified Capabilities

(없음 — `wms_wcs-equipment-control`(area1)의 기존 Requirement를 변경하지
않는다. area1이 열어 둔 `WCS_GATEWAY` 서비스 아이덴티티와 명령 결과 보고
계약을 소비할 뿐이다. area2~5가 이미 각자의 확장 지점 표에서 예견한 대로,
이 변경이 `wms_report_command_result`를 호출하면 그 계약들의 트리거·검증도
그대로 반응하며 그 스펙들 자체는 수정하지 않는다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 4종(`wms.simulation_profiles`,
  `wms.simulation_command_schedules`, `wms.simulation_scenarios`,
  `wms.simulation_scenario_runs`), 신규 RPC 10종, 신규 RLS 정책 추가.
  `wms_wcs-equipment-control`(area1)의 `wms.equipment`에 `is_simulated`
  컬럼을 추가하는 마이그레이션을 얹는다(그 테이블은 이 변경이 아니라 area1이
  소유 — 배포 순서 의존성이 생긴다, design.md 참고). 기존
  `20260726_wms_core_schema.sql`의 테이블/RPC는 변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 10종 추가. 기존 도구는
  변경하지 않는다.
- **신규 실행 자산**: `WCS_GATEWAY`로 인증하는 폴링 워커 스크립트(신규
  프로세스, 신규 서비스 아님) — E2E와 데모 실행 시 별도로 기동해야 한다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/wcs/simulation`(프로파일 관리·진행 현황), `/wcs/scenario-planner`(시나리오
  정의·실행·결과 비교) 라우트가 추후 이 계약 위에 얹힐 수 있음을 design.md에
  확장 지점으로만 기록한다.
- **역할 모델**: 변경 없음(`WCS_GATEWAY` 포함 기존 역할 재사용).
- **선행 의존성**: 이 변경은 `add-wcs-equipment-control-contract`(area1,
  capability `wms_wcs-equipment-control`)의 `wms.equipment`,
  `wms.equipment_commands`, `wms_dispatch_equipment_command`,
  `wms_report_command_result`, `WCS_GATEWAY` 역할을 전제로 한다. area1은
  아직 구현되지 않았으므로, 이 변경의 마이그레이션도 실제 DB에는 area1의
  마이그레이션이 먼저 적용된 뒤에만 적용할 수 있다. **area2~5(`wms_wes-material-flow-control`,
  `wms_wcs-sortation-logic`, `wms_wcs-bottleneck-routing`,
  `wms_wcs-sequential-dispatch`)에는 하드 스키마 의존성이 없다** — 이 변경의
  시나리오 계약은 웨이브/업무 오더를 느슨한 참조로만 다루고, 실제 대상
  건수는 호출자가 넘겨준다(design.md D8). 다섯 영역 전부가 구현되어 있으면
  더 풍부한 시나리오를 구성할 수 있지만, 이 변경 자체는 area1만으로 독립
  동작한다.
- **제외 범위(명시적)**: 3D 모션/물리 시뮬레이션, 실제 PLC/필드버스 프로토콜,
  결정론적 재현(시드 고정) 시뮬레이션, ML/최적화 기반 시나리오 자동 탐색,
  큐잉 이론 기반 정밀 대기시간 모델은 이 변경에 포함하지 않는다 — design.md
  Non-Goals와 §5 표에 정직하게 남긴다.
- **후속 영역**: 이 변경은 WCS/WES 계열 스펙 시리즈(area1~6)의 마지막
  항목이다. 이후 항목(야드/도크, 인력 관리, 슬롯팅, 에이전틱 AI, 감사 로그)은
  WCS/WES와 무관한 별도 계열이므로 이 변경의 확장 지점으로 다루지 않는다.
