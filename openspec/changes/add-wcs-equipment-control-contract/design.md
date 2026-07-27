## Context

이 저장소의 `wms` 스키마(`supabase/migrations/20260726_wms_core_schema.sql`)는
현재 사람이 수행하는 문서 중심 업무(구매→입고→검수→적치)만 모델링한다.
`docs/04-wms-wcs-market-feature-catalog.md`가 정리한 실제 WMS/WCS 제품 조사
결과, "자동화 설비 직접 제어"와 "실시간 모니터링/예외 복구"는 시장 전반의 공통
기능이지만, 이 샘플 앱에는 그에 대응하는 계약이 전혀 없다.

동시에 main repo `openspec/changes/supabase-wms-erp-replacement/design.md` §3은
"자동창고 설비 PLC/WCS의 저수준 제어"를 1차 범위 밖으로 명시한다. 이 설계는 그
경계를 지킨다 — PLC 프로토콜, 실시간 제어 루프, 하드웨어 드라이버는 다루지
않는다. 대신 **WMS가 설비에게 무엇을 요청하고, 설비가 WMS에게 무엇을
돌려주는지**를 규정하는 소프트웨어 계약(RPC/이벤트 인터페이스)만 정의한다. 이
계약을 실제로 채우는 쪽은 진짜 WCS/PLC 게이트웨이일 수도, 데모용 소프트웨어
시뮬레이터일 수도 있다 — 계약은 둘 중 무엇이 채우든 동일하게 동작해야 한다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새 테이블과
RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한 RLS/RPC 봉투
관례를 그대로 확장한다.

### `warehouse_tasks` 관련 확인 사항

작업 지시서는 "기존 `wms.warehouse_tasks`-shaped concept과의 연결"을 요청했다.
실제로 확인한 결과 **이 저장소의 스키마에는 `wms.warehouse_tasks` 테이블이
존재하지 않는다.** `wms_create_putaway_tasks` RPC는 이름과 달리 별도 작업
테이블을 만들지 않고, `wms.receipts`의 상태 전이와 원장 반영을 하나의 호출로
축약한 데모 슬라이스 구현이다(`supabase/migrations/20260726_wms_core_schema.sql`
주석: "collapses task-lifecycle (7.1) into a single call for this slice"). 카탈로그
매핑 문서(§5)의 "창고 작업 실행 전반 → `wms_warehouse-task-execution`"은 아직
이 저장소에 구현되지 않은, main repo 쪽 스펙만 존재하는 항목이다.

따라서 이 설계는 `wms.warehouse_tasks`가 존재한다고 가정하지 않는다. 대신
`wms.equipment_commands`가 WMS 쪽 작업과 맺는 관계를 느슨한 참조
(`linked_entity_type text` + `linked_entity_id uuid`, 예: `'receipt'` +
`receipts.id`)로 설계해, 나중에 `warehouse_tasks` 또는 유사 테이블이 생기더라도
마이그레이션 없이 `linked_entity_type` 값만 추가하면 연결되도록 한다.

## Goals / Non-Goals

**Goals:**

- 자동화 설비를 테넌트·창고 스코프 안에서 등록·조회할 수 있는 레지스트리.
- 기존 RPC와 동일한 명령 봉투(`tenant_id`, `warehouse_id`, `actor_id`,
  `idempotency_key`, `expected_version`, `correlation_id`)로 설비에 제어 명령을
  디스패치하는 계약.
- 설비가 명령 처리 결과와 독립적 상태 변화를 WMS에 실시간으로 피드백하는 계약.
- 장애 발생 시 진행 중이던 명령을 안전하게 종결하고, 사람이 확인 후 재가동할 수
  있는 복구 절차.
- 다섯 개 후속 영역(고속 분류 제어, 지능형 라우팅/병목 해소, 서열 출고/지능형
  적재, 디지털 트윈/시뮬레이션, WES/MFS 자재 흐름 제어)이 새 설비 개념을 다시
  만들지 않고 이 위에 얹을 수 있는 확장 지점.

**Non-Goals:**

- 실제 PLC/필드버스 프로토콜(OPC-UA, Modbus 등) 구현 — main repo design.md §3
  제외 범위와 일치.
- 고속 분류(Carton Gapping, Divert, 가변 속도 제어) 로직 — 후속 스펙
  `wms_wcs-sortation-logic`(가칭)에서 다룬다.
- 병목 감지·경로 재설정 알고리즘 — 후속 스펙(지능형 라우팅)에서 다룬다.
- 서열 출고 순서 계산, 다중 로봇 셀 팔레타이징 최적화 — 후속 스펙(서열
  출고/지능형 적재)에서 다룬다.
- 디지털 트윈 시뮬레이션 엔진 — 후속 스펙에서 다룬다.
- WMS 작업(입고/적치/출고)을 설비 명령으로 자동 변환하는 미들웨어 라우팅 로직 —
  후속 스펙 `wms_wes-material-flow-control`(가칭, WES/MFS 계층)에서 다룬다. 이번
  변경은 그 라우팅이 호출할 **대상 계약**만 제공한다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 신규 테이블은 기존 공통 컬럼 관례를 따르되 살짝 강화한다

기존 테이블(`purchase_orders`, `receipts`)은 `created_by`만 있고 `updated_by`가
없다. 이번 변경은 작업 지시에 따라 `id / tenant_id / warehouse_id / status /
version / created_at / created_by / updated_at / updated_by / correlation_id`를
신규 테이블의 공통 컬럼으로 삼는다 — 설비 제어는 "누가 마지막으로 이 상태를
바꿨는가"가 장애 대응에서 특히 중요하기 때문에 기존 관례보다 한 칸 더 엄격하게
간다. 이는 기존 테이블을 바꾸지 않으므로 하위 호환에 영향이 없다.

### D2. 설비 상태·명령 상태·장애 상태를 3개의 독립된 상태 기계로 분리한다

하나의 "설비 상태" 컬럼에 명령 진행 상황과 장애를 모두 욱여넣지 않는다.

- `wms.equipment.status`: `OFFLINE | IDLE | RUNNING | FAULT | MAINTENANCE`
  — 설비 자체의 가동 가능 여부.
- `wms.equipment_commands.status`: `PENDING | ACKNOWLEDGED | IN_PROGRESS |
  COMPLETED | FAILED | REJECTED | CANCELLED` — 개별 명령의 생애주기.
- `wms.equipment_faults.status`: `OPEN | RESOLVED` — 장애 자체의 생애주기.

세 상태 기계를 분리하면 "설비는 RUNNING인데 특정 명령만 실패했다"거나 "장애는
해소됐지만 그 장애로 실패한 명령은 여전히 FAILED로 남아 이력이 보존된다" 같은
현실적 상황을 잃어버리지 않고 표현할 수 있다. 실시간 모니터링 화면은 이 세 상태를
조인해서 보여주면 된다.

### D3. 명령 결과 보고와 설비 상태 보고를 분리한다

`wms_report_command_result`(특정 명령에 대한 결과)와
`wms_report_equipment_status`(명령과 무관한 상태 푸시, 예: 기동/오프라인 전환)를
별개 RPC로 둔다. 하나로 합치면 "이 상태 변화가 어떤 명령 때문인지"를 매번
optional 필드로 구분해야 해서 낙관적 동시성 검증(어느 버전을 검증할지: 설비
버전인지 명령 버전인지)이 모호해진다. 분리하면 각 RPC가 검증할 `expected_version`
대상이 명확해진다(전자는 명령 버전, 후자는 설비 버전).

### D4. 장애 발생 시 진행 중 명령을 자동으로 FAILED 처리한다

카탈로그의 "비상 장애 시나리오 기반 실시간 복구" 패턴을 반영해,
`wms_raise_equipment_fault`는 해당 설비의 `PENDING`/`ACKNOWLEDGED`/`IN_PROGRESS`
명령을 모두 `FAILED`로 일괄 전환하고 장애 레코드와 연결한다. 대안으로 "장애와
무관하게 명령은 그대로 두고 별도 정리 절차를 요구"하는 설계도 고려했으나, 그러면
장애 중에도 명령이 `IN_PROGRESS`로 남아 모니터링 화면과 후속 재시도 로직이
"이 설비가 지금 뭔가 하고 있다"고 잘못 판단할 위험이 있어 기각했다.

### D5. 설비 측 피드백은 별도 서비스 역할(`WCS_GATEWAY`)로 인증한다

`PROCESS_AGENT`가 이미 "허용된 MCP 명령만 실행하는 service identity" 패턴으로
존재하지만(main repo design.md §12), 설비 게이트웨이는 성격이 다르다 —
`PROCESS_AGENT`는 ProcessGPT가 WMS에 지시를 "내리는" 쪽이고, 설비 게이트웨이는
설비가 WMS에 결과를 "돌려주는" 쪽이다. 두 역할을 분리해야 "명령을 내릴 수 있는
자"와 "명령 결과를 보고할 수 있는 자"를 RLS에서 독립적으로 통제할 수 있고, 이후
실제 PLC 게이트웨이를 붙일 때 그 자격증명에 `WCS_GATEWAY`만 부여하면 되어 사고
반경이 좁아진다. 이 역할은 실제 하드웨어 유무와 무관하게 동작한다 — 데모에서는
소프트웨어 시뮬레이터가 `WCS_GATEWAY`로 인증해 이 계약을 채운다.

### D6. `linked_entity_type` / `linked_entity_id`는 느슨한 참조로 둔다

명령이 참조하는 WMS 쪽 작업을 외래키가 아니라 `(text, uuid)` 쌍으로 둔다. 지금은
`'receipt'`만 유효한 값이지만(입고→적치 흐름), 후속 스펙이 출고 웨이브, 서열
적재 작업 등을 추가할 때 새 테이블마다 `equipment_commands`에 FK 컬럼을 추가하는
스키마 변경 없이 `linked_entity_type` 값만 늘리면 된다. 참조 무결성은 이 계약의
책임이 아니다 — 값의 의미를 해석하고 반응하는 것은 각 소비 스펙의 책임이다.

### D7. 명령 타입은 열린 집합으로 둔다

`command_type`은 CHECK 제약으로 기본 집합(`MOVE`, `LOAD`, `UNLOAD`, `START`,
`STOP`, `RESET`, `HOLD`, `RESUME`)만 강제하고, 명령별 세부값은 전부 `payload
jsonb`에 담는다. 고속 분류(Divert 슈트 번호, 가변 속도 값)나 서열 적재(적재
순서 인덱스) 같은 도메인 특화 파라미터는 이번 스펙이 미리 정의하지 않는다 —
후속 스펙이 `payload` 안에 자신의 필드를 정의하거나, 필요하면 `command_type` 값
집합을 확장하는 마이그레이션만 추가하면 된다. 테이블 구조 자체는 바뀌지 않는다.

## 데이터 모델 (검토용 후보)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은 구현 단계에서
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`은 수정하지 않는다.

### `wms.equipment` — 설비 레지스트리

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` | `uuid` | FK `wms.tenants` |
| `warehouse_id` | `uuid` | FK `wms.warehouses` |
| `equipment_code` | `text` | 창고 내 고유 (unique `(warehouse_id, equipment_code)`) |
| `equipment_type` | `text` | `SRM \| CONVEYOR \| SORTER \| AGV \| AMR \| ROBOT_CELL` |
| `zone_code` | `text` | 설비가 위치한 구역/로케이션 식별자 |
| `status` | `text` | `OFFLINE \| IDLE \| RUNNING \| FAULT \| MAINTENANCE` |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | 등록을 트리거한 상위 요청과의 상관관계 |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.equipment_commands` — 명령 디스패치 로그

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `equipment_id` | `uuid` | FK `wms.equipment` |
| `command_type` | `text` | `MOVE \| LOAD \| UNLOAD \| START \| STOP \| RESET \| HOLD \| RESUME` |
| `payload` | `jsonb` | 명령별 세부 파라미터 (D7) |
| `status` | `text` | `PENDING \| ACKNOWLEDGED \| IN_PROGRESS \| COMPLETED \| FAILED \| REJECTED \| CANCELLED` |
| `linked_entity_type` | `text` | 예: `'receipt'` (D6, nullable) |
| `linked_entity_id` | `uuid` | nullable |
| `fault_id` | `uuid` | FK `wms.equipment_faults`, 장애로 인해 FAILED 처리된 경우만 채움 |
| `version` | `int` | 낙관적 동시성 (명령 자체의 버전, D3) |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.equipment_status_events` — 상태/이벤트 피드 (append-only)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `equipment_id` | `uuid` | FK `wms.equipment` |
| `command_id` | `uuid` | FK `wms.equipment_commands`, nullable (명령과 무관한 이벤트면 null) |
| `event_type` | `text` | `STATUS_CHANGED \| COMMAND_ACKNOWLEDGED \| COMMAND_PROGRESS \| COMMAND_COMPLETED \| COMMAND_FAILED \| FAULT_RAISED \| FAULT_CLEARED` |
| `previous_status` | `text` | 이벤트 발생 전 설비 상태 |
| `new_status` | `text` | 이벤트 발생 후 설비 상태 |
| `detail` | `jsonb` | 자유 형식 상세 (센서값, 실패 사유 등) |
| `reported_by` | `uuid` | 보고한 actor(대개 `WCS_GATEWAY` 아이덴티티) |
| `correlation_id` | `text` | |
| `created_at` | `timestamptz` | 이벤트는 불변 — `updated_*` 컬럼 없음 |

이 테이블은 `wms.stock_ledger_entries`와 같은 성격(append-only 사실 기록)이라
공통 컬럼 관례 중 `status`/`version`/`updated_*`는 적용하지 않는다 — 이벤트
자체는 상태 전이 대상이 아니라 사실의 기록이기 때문이다.

### `wms.equipment_faults` — 장애 기록

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `equipment_id` | `uuid` | FK `wms.equipment` |
| `fault_code` | `text` | |
| `severity` | `text` | `WARNING \| CRITICAL \| BLOCKING` |
| `status` | `text` | `OPEN \| RESOLVED` |
| `raised_by` | `uuid` | 대개 `WCS_GATEWAY`, 수동 보고 시 `WCS_OPERATOR` |
| `resolution_note` | `text` | 해소 시 필수 |
| `resolved_by` | `uuid` | nullable |
| `resolved_at` | `timestamptz` | nullable |
| `version` | `int` | |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

## RPC 계약 (검토용 시그니처 초안)

모든 RPC는 기존과 동일하게 `language plpgsql security definer set search_path =
wms, public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only)를 따른다.

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_register_equipment` | `p_tenant_id, p_warehouse_id, p_equipment_code, p_equipment_type, p_zone_code, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | 신규 설비, `status='OFFLINE'` |
| `wms_dispatch_equipment_command` | `p_equipment_id, p_command_type, p_payload jsonb, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null, p_linked_entity_type default null, p_linked_entity_id default null` | `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT` | `expected_version`은 설비 버전 |
| `wms_report_command_result` | `p_command_id, p_command_status, p_detail jsonb default null, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WCS_GATEWAY`, `WMS_ADMIN` | `expected_version`은 명령 버전 |
| `wms_report_equipment_status` | `p_equipment_id, p_new_status, p_detail jsonb default null, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WCS_GATEWAY`, `WMS_ADMIN` | `expected_version`은 설비 버전 |
| `wms_raise_equipment_fault` | `p_equipment_id, p_fault_code, p_severity, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WCS_GATEWAY`, `WCS_OPERATOR`, `WMS_ADMIN` | 진행 중 명령 일괄 FAILED (D4) |
| `wms_resolve_equipment_fault` | `p_fault_id, p_resolution_note, p_actor_id, p_idempotency_key, p_expected_version` | `WCS_OPERATOR`, `WAREHOUSE_MANAGER`, `WMS_ADMIN` | `WCS_GATEWAY`는 호출 불가 |
| `wms_cancel_equipment_command` | `p_command_id, p_actor_id, p_idempotency_key, p_expected_version, p_reason default null` | `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`, `WMS_ADMIN` | 종결 상태에서는 거부 |
| `wms_get_equipment_status` | `p_tenant_id, p_warehouse_id, p_equipment_id default null` | 모든 테넌트/창고 멤버(읽기) | `wms_check_stock`처럼 조인된 조회 전용 함수 — 설비 + 최근 이벤트 N건 + 열린 장애 |

모든 쓰기 RPC는 성공 시 `{result: 'ok', document_id, status, version,
next_actions, warnings?}` 형태를 반환하고, 각각 `wms.audit_events`에
`entity_type in ('equipment', 'equipment_command', 'equipment_fault')` 레코드를
남긴다.

## 역할 모델 확장

기존 역할 집합(main repo design.md §12)에 두 역할을 추가한다:

| 역할 | 권한 |
|---|---|
| `WCS_OPERATOR` | 설비 모니터링, 수동 명령 디스패치, 장애 해소 |
| `WCS_GATEWAY` | 명령 결과/상태 보고, 장애 발생 보고 — 사람 화면 로그인이 아닌 service identity (`PROCESS_AGENT`와 대칭되는, 설비 쪽 service identity, D5) |

`WMS_ADMIN`, `WAREHOUSE_MANAGER`는 설비 레지스트리 관리와 장애 해소에도 접근한다.
`PROCESS_AGENT`는 명령 디스패치·취소는 가능하지만(WES/MFS 자동 라우팅을 위해),
결과 보고나 장애 해소는 할 수 없다 — 그건 설비 쪽(`WCS_GATEWAY`)과 사람
운영자(`WCS_OPERATOR`) 몫이다.

## RLS 패턴

기존 테이블과 동일하게, 신규 4개 테이블 모두:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer` RPC를
  통해서만 이루어진다(기존 D3 원칙 유지).
- `wms.equipment_status_events`는 append-only이므로 `update`/`delete` 경로 자체가
  RPC에도 없다.

## 확장 지점 (다섯 개 후속 영역)

| 후속 영역 (가칭 spec ID) | 이 계약을 어떻게 확장하는가 |
|---|---|
| `wms_wcs-sortation-logic`(고속 분류 제어) | `equipment_type='SORTER'`에 대해 `command_type`을 확장(`DIVERT`, `SET_SPEED`)하거나 `payload`에 Carton Gapping/속도 값을 담는다. 새 테이블 불필요. |
| `wms_wcs-intelligent-routing`(지능형 라우팅/병목 해소) | `wms.equipment_status_events`와 `wms.equipment_commands`의 처리량·대기시간을 관찰해 병목을 감지하고, 감지 결과로 새 `MOVE`/`REROUTE` 명령을 디스패치한다. 이 계약의 소비자로만 동작. |
| `wms_wcs-sequential-dispatch`(서열 출고/지능형 적재) | `linked_entity_type='outbound_wave'` 같은 새 값과, `payload`에 적재 순서 인덱스를 담아 `ROBOT_CELL` 대상 명령을 디스패치한다. |
| `wms_wes-digital-twin`(디지털 트윈/시뮬레이션) | `WCS_GATEWAY` 역할로 인증하는 시뮬레이터 자체가 이 계약의 첫 구현체가 된다 — `wms_report_command_result`/`wms_report_equipment_status`를 시뮬레이션 결과로 호출. |
| `wms_wes-material-flow-control`(WES/MFS 자재 흐름 제어) | WMS 작업(입고 적치, 출고 피킹)을 어떤 설비에, 어떤 순서로 명령을 디스패치할지 결정하는 미들웨어 로직. `wms_dispatch_equipment_command`/`linked_entity_type='receipt'` 등을 호출하는 오케스트레이션 계층. |

## 프론트엔드 확장 지점 (구현 아님, 위치만 기록)

- `/wcs/equipment` — 설비 레지스트리 화면(등록/목록/유지보수 모드 전환). 기존
  `frontend/src/views/`에 `EquipmentView.vue` 형태로 추가될 후보.
- `/wcs/monitor` — 실시간 상태·이벤트·장애 모니터링 화면(카탈로그의 "실시간
  모니터링" 패턴). `wms.equipment_status_events`, `wms.equipment_faults`를
  Supabase Realtime으로 구독하는 화면 후보.

이번 변경은 위 두 화면을 구현하지 않는다 — RPC/MCP 계약만 제공한다.

## Risks / Trade-offs

- **실제 하드웨어 부재로 계약의 현실성 검증이 어렵다.** 완화책: 이 스펙의 E2E는
  소프트웨어 시뮬레이터(단순 상태 머신 스크립트가 `WCS_GATEWAY` 자격으로 RPC를
  호출)로 검증한다 — 실제 PLC가 붙어도 같은 RPC만 호출하면 되므로 계약 자체의
  타당성은 시뮬레이터로도 검증 가능하다.
- **`linked_entity_type`을 느슨한 참조로 둔 것은 참조 무결성을 포기하는
  트레이드오프다.** 완화책: `linked_entity_id`가 가리키는 대상이 삭제되는
  일(receipt 삭제 등)은 이 스키마에 없으므로(원장은 불변, 상태 전이만 존재)
  현재는 위험이 낮다. 후속 영역이 늘어나면 `linked_entity_type` 값 집합을
  문서화된 enum으로 승격하는 것을 고려한다.
- **`WCS_GATEWAY`라는 새 service identity를 도입하는 것은 권한 모델의 표면을
  넓힌다.** 완화책: `PROCESS_AGENT`와 동일하게 "허용된 RPC만 실행하는 좁은
  scope"로 문서화하고, tasks.md에 시드 데이터/데모 계정 준비 작업을 포함한다.
- **장애 발생 시 진행 중 명령을 자동으로 FAILED 처리하는 것(D4)은 되돌릴 수
  없다.** 명령이 사실은 거의 끝났는데 장애 감지가 늦게 도착한 경우에도 FAILED로
  종결된다. 완화책: 명령 재시도는 이 계약의 책임이 아니라 소비 스펙(WES/MFS
  라우팅)의 책임으로 명확히 분리했다 — 이 계약은 "안전하게 종결"까지만 보장한다.
