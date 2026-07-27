## Context

`add-wcs-equipment-control-contract`(capability `wms_wcs-equipment-control`,
아직 미구현)는 WMS가 자동화 설비를 등록·지시·모니터링하는 소프트웨어 계약을
정의했다. 그 스펙은 `wms.equipment_commands`가 WMS 쪽 작업을 느슨하게 참조하는
`linked_entity_type`/`linked_entity_id`를 가질 수 있다고 정의하면서도, "누가 그
값을 채우는가"와 "명령 결과가 보고되면 그 참조 대상의 상태를 어떻게 되돌리는가"는
의도적으로 열어 뒀다(그 스펙 D6, "명령 결과 보고" Requirement). 이 변경은 그
빈틈을 채우는 **첫 번째 소비 스펙**이다.

`docs/04-wms-wcs-market-feature-catalog.md` §2.2가 정리한 실제 WES/MFS 제품
동향(Dematic iQ Optimize의 Wave/Waveless/Hybrid, SAP EWM의 내장 MFS, Swisslog
SynQ의 단일 통합 아키텍처)은 이 계층이 "무엇을 할지"(WMS)와 "어떻게 실행할지"
(WCS) 사이에서 (1) 언제 작업을 실행할지 결정하고 (2) 설비 간 흐름을 배분한다는
공통점을 보여준다. 이 설계는 그 두 가지만 다룬다 — 고속 분류, 병목 예측,
서열 적재, 디지털 트윈 같은 도메인 특화 로직은 후속 스펙(§ 확장 지점)에
남겨 둔다.

### 정직한 전제 확인 (구현 상태)

- **`wms_wcs-equipment-control`은 아직 구현되지 않았다.** `supabase/migrations/`에
  해당 마이그레이션 파일이 없다. 이 설계가 참조하는 `wms.equipment`,
  `wms.equipment_commands`, `wms.wms_dispatch_equipment_command` 등은 그 스펙의
  design.md에 있는 **검토용 후보**이며, 실제 DB에는 존재하지 않는다. 이 변경의
  마이그레이션은 그 변경의 마이그레이션이 먼저 적용된 뒤에만 적용할 수 있다
  (tasks.md 1장 참고).
- **이 저장소의 스키마에는 `wms.warehouse_tasks`가 없다.** 확인 결과
  `wms_create_putaway_tasks`(`supabase/migrations/20260726_wms_core_schema.sql`)는
  별도 작업 테이블을 만들지 않고, `wms.receipts` 상태 전이와 원장 반영을 한
  호출로 축약한 데모 슬라이스 구현이다 — 호출 즉시 동기적으로
  `PUTAWAY_COMPLETED`와 `AVAILABLE` 원장 반영까지 끝난다. 즉 **오늘 시점의
  실제 적치 흐름은 설비 실행을 전혀 기다리지 않는다.** 이 계약이 정의하는
  업무 오더가 실제로 `wms_create_putaway_tasks` 호출을 대체하거나 그 앞단에
  끼워 넣어지려면 별도의 통합 변경이 필요하다 — 이 변경은 그 통합 자체를
  하지 않는다(아래 Non-Goals).
- **main repo design.md §9.2의 `wms_release_wave`(wave와 피킹 작업 생성)는
  이 저장소에 구현되지 않은, 목표 아키텍처 문서에만 있는 RPC다.** 이 설계가
  정의하는 "웨이브"는 그 RPC와 이름만 유사할 뿐 다른 계약이다 — 이 계약의
  웨이브는 피킹 작업이 아니라 **설비 명령 디스패치 타이밍**을 배치하는
  최소 데이터 계약이다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블과 RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

## Goals / Non-Goals

**Goals:**

- WMS 상위 작업 의도를 업무 오더로 등록하는 계약.
- Wave(배치 큐잉 후 릴리즈)와 Waveless(즉시 디스패치) 두 이행 전략을 데이터
  계약으로 표현.
- 업무 오더를 적합한 가용 설비에 번역·디스패치하는 로직과, 설비 간 흐름을
  단순하게 배분하는 부하 분산.
- `wms_wcs-equipment-control`의 "명령 결과 보고"가 열어 둔 구독 지점을 채워,
  설비 명령 완료/실패가 업무 오더 상태로 자동 반영되도록 하는 완료 전파.
- 후속 네 영역(고속 분류 제어, 지능형 라우팅/병목 해소, 서열 출고/지능형
  적재, 디지털 트윈/시뮬레이션)이 이 미들웨어를 다시 만들지 않고 그 위에
  얹을 수 있는 확장 지점.

**Non-Goals:**

- 실제 PLC/필드버스 제어 — 여전히 `wms_wcs-equipment-control`이 정의하는
  설비 계약 뒤에 있다.
- **업무 오더 완료를 상위 WMS 엔티티(`wms.receipts` 등)의 실제 상태 전이로
  자동 연결하는 것.** 예를 들어 업무 오더가 `COMPLETED`가 되었다고 해서 이
  계약이 자동으로 `wms_create_putaway_tasks`를 호출하거나 `wms.receipts`를
  갱신하지 않는다 — 업무 오더 상태 변화를 관찰해 상위 엔티티의 다음 전이를
  호출하는 것은 이 계약을 다시 소비하는 오케스트레이션(ProcessGPT 프로세스
  또는 후속 통합 변경)의 책임이다. 이는 `wms_wcs-equipment-control`이 자신의
  경계를 그은 것과 동일한 원칙을 한 단계 위에서 반복하는 것이다.
- 고속 분류(Carton Gapping, Divert, 가변 속도 제어) 로직 — 후속 스펙
  `wms_wcs-sortation-logic`(가칭)에서 다룬다.
- 병목 감지·경로 재설정 알고리즘, ML 기반 최적 설비 선택 — 후속 스펙(지능형
  라우팅)에서 다룬다. 이 설계의 부하 분산은 "미종결 명령이 있으면 제외 +
  최근 완료 건수가 적은 순"이라는 단순 규칙일 뿐이다.
- 서열 출고 순서 계산, 다중 로봇 셀 팔레타이징 최적화 — 후속 스펙(서열
  출고/지능형 적재)에서 다룬다.
- 디지털 트윈 시뮬레이션 엔진 — 후속 스펙에서 다룬다.
- 웨이브 계획 UI, 웨이브 릴리즈 일정 최적화, 다중 웨이브 우선순위 조정 —
  이 계약은 "큐잉 vs 즉시"라는 최소 데이터 계약만 제공한다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 업무 오더는 receipt를, 설비 명령은 업무 오더를 참조하는 2단 간접 참조로 둔다

`wms_wcs-equipment-control`의 D6(느슨한 참조)를 그대로 재사용하되, 참조 사슬을
한 단계 늘린다: `wms.work_orders.linked_entity_type/linked_entity_id`가
WMS 상위 엔티티(`'receipt'` 등)를 가리키고, 이 업무 오더를 디스패치할 때 생성되는
`wms.equipment_commands`는 `linked_entity_type='work_order'`,
`linked_entity_id=work_order.id`로 업무 오더 자신을 가리킨다. 대안으로
"설비 명령이 receipt를 직접 가리키게 한다"도 고려했으나, 그러면
`wms_wcs-equipment-control`이 `'receipt'`, `'outbound_wave'` 같은 WMS 도메인
값을 알아야 하고, 하나의 업무 오더가 여러 설비 명령으로 번역되는 경우(예: 이동
후 적재처럼 다단계 명령)를 표현할 곳이 없다. 2단 참조는 각 계층이 자신의
도메인만 알게 하면서, 1:N(업무 오더 : 설비 명령) 확장 여지도 남긴다 — 이번
변경은 1:1만 구현하지만 테이블 구조는 1:N을 막지 않는다.

### D2. 완료 전파는 `wms.equipment_commands`에 대한 트리거로 구현한다

업무 오더 상태를 폴링이나 별도 RPC 호출로 동기화하지 않고, `wms_wcs-equipment-control`이
소유한 `wms.equipment_commands` 테이블에 `AFTER UPDATE OF status` 트리거를
추가해 `linked_entity_type='work_order'`이고 새 상태가 `COMPLETED`/`FAILED`일
때 해당 업무 오더를 즉시 갱신한다. 대안으로 "이 스펙이 `wms_get_work_order_status`
조회 때마다 연결된 명령 상태를 계산해서 보여주기만 하고, 실제 컬럼은 갱신하지
않는다"도 고려했으나, 그러면 스펙 자체의 "명령 결과 보고 반영" Requirement가
관찰 가능한 상태 변화가 아니라 조회 시점의 파생값이 되어 감사·이벤트 추적이
약해진다. 트레이드오프: 이 트리거는 **다른 변경이 소유한 테이블에 얹히는
교차 스펙 의존성**이다 — `wms_wcs-equipment-control`이 먼저 구현된 뒤에만 이
트리거를 추가할 수 있고, 그 변경의 마이그레이션 순서를 tasks.md에 명시해야
한다.

### D3. 이 계약의 쓰기 RPC 호출 역할은 설비 명령 디스패치가 가능한 역할의 부분집합으로 제한한다

업무 오더 디스패치 로직은 내부적으로 `wms_wcs-equipment-control`의
`wms_dispatch_equipment_command`/`wms_cancel_equipment_command`를 **같은
호출자 신원(`auth.uid()`)으로** 호출한다(둘 다 `SECURITY DEFINER`이지만 역할
검사는 `auth.uid()` 기준이다). 따라서 이 계약의 쓰기 RPC를 호출할 수 있는
역할 집합(`WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`, `WMS_ADMIN`)은
그 RPC를 호출할 수 있는 역할 집합과 정확히 일치하도록 맞춘다 — 그렇지 않으면
"업무 오더 등록은 성공했지만 내부 디스패치 호출이 `FORBIDDEN`으로 실패"하는
혼란스러운 부분 실패가 생긴다.

### D4. 새 service role을 추가하지 않는다

`wms_wcs-equipment-control`은 설비 쪽 피드백을 위해 `WCS_GATEWAY`를 도입했다.
이 계층은 설비가 아니라 **WMS 내부 오케스트레이션**(사람 운영자 또는
`PROCESS_AGENT`)이 호출한다 — 업무 오더를 만들고, 웨이브를 릴리즈하고,
재시도·취소를 판단하는 주체는 항상 WMS 쪽이다. 따라서 기존 4개 역할
(`WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`, `WMS_ADMIN`)로 충분하며,
권한 모델의 표면을 넓히지 않는다.

### D5. 흐름 균형은 "제외 + 최근 완료 건수 최소"라는 단순 규칙으로 한정한다

카탈로그의 "설비 간 흐름 균형 유지"를 문자 그대로 만족시키되, 현대무벡스의
"병목 현상 해소 알고리즘"이나 Dematic iQ의 "래피드 버퍼 기반 동적 제어" 같은
실시간 최적화는 다루지 않는다. 후보 설비 선택은 (1) 조건 일치(`equipment_type`,
`zone_code`, `status='IDLE'`) (2) 미종결 명령 없음 (3) 최근 시간 창 내
`COMPLETED` 명령 수 최소, 세 단계로 끝난다. 이는 "병목이 이미 생긴 뒤 우회"가
아니라 "애초에 한쪽으로 쏠리지 않게" 하는 예방적 라운드로빈에 가깝다 —
후속 "지능형 라우팅/병목 해소" 스펙이 실시간 처리량 관찰과 재라우팅을 더한다.

### D6. Wave는 최소 데이터 계약만 제공한다

실제 벤더의 웨이브 플래닝(주문 묶음 전략, 릴리즈 일정 최적화, 우선순위 조정)은
다루지 않는다. `wms.dispatch_waves`는 `OPEN → RELEASED` 두 상태만 가지며,
업무 오더를 웨이브에 묶고 릴리즈 시점에 일괄 디스패치를 시도하는 최소 계약
역할만 한다. 웨이브를 여러 개 동시에 열어 둘 수 있고(창고당 동시에 여러 `OPEN`
웨이브 허용), 어떤 웨이브에 담을지는 업무 오더 등록 시 호출자가 명시적으로
`wave_id`를 지정한다 — 이 계약이 자동으로 웨이브를 배정하지 않는다.

## 데이터 모델 (검토용 후보)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은 구현 단계에서
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`은 수정하지 않으며, `wms_wcs-equipment-control`이
> 구현된 뒤에만 적용할 수 있다.

### `wms.dispatch_waves` — 디스패치 웨이브

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` | `uuid` | FK `wms.tenants` |
| `warehouse_id` | `uuid` | FK `wms.warehouses` |
| `status` | `text` | `OPEN \| RELEASED` |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `released_at` | `timestamptz` | nullable |
| `released_by` | `uuid` | nullable |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.work_orders` — WES/MFS 업무 오더

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `work_order_type` | `text` | `PUTAWAY`(현재 유일한 값, 열린 집합 — D7과 동일 패턴) |
| `linked_entity_type` | `text` | `'receipt'`(현재 유일한 값, nullable 아님) |
| `linked_entity_id` | `uuid` | 상위 WMS 엔티티 id |
| `equipment_type` | `text` | 목표 설비 종류(`wms_wcs-equipment-control`의 `equipment_type` 값 집합 재사용) |
| `zone_code` | `text` | 목표 구역 |
| `command_type` | `text` | 디스패치할 설비 명령 종류(`wms_wcs-equipment-control`의 `command_type` 값 집합 재사용) |
| `command_payload` | `jsonb` | 디스패치할 설비 명령의 `payload`로 그대로 전달 |
| `dispatch_mode` | `text` | `WAVE \| WAVELESS` |
| `wave_id` | `uuid` | FK `wms.dispatch_waves`, `dispatch_mode='WAVE'`일 때만 not null |
| `status` | `text` | `QUEUED \| DISPATCHED \| COMPLETED \| FAILED \| CANCELLED` |
| `equipment_command_id` | `uuid` | FK `wms.equipment_commands`, 디스패치 성공 후에만 채움 |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

## RPC 계약 (검토용 시그니처 초안)

모든 RPC는 기존과 동일하게 `language plpgsql security definer set search_path =
wms, public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only)를 따른다.

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_open_dispatch_wave` | `p_tenant_id, p_warehouse_id, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `PROCESS_AGENT`, `WMS_ADMIN` | 신규 웨이브, `status='OPEN'` |
| `wms_create_work_order` | `p_tenant_id, p_warehouse_id, p_work_order_type, p_linked_entity_type, p_linked_entity_id, p_equipment_type, p_zone_code, p_command_type, p_command_payload jsonb, p_dispatch_mode, p_actor_id, p_idempotency_key, p_wave_id default null, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT`, `WMS_ADMIN` | `WAVELESS`면 등록 트랜잭션 안에서 즉시 디스패치 시도(D3의 역할 제약) |
| `wms_release_dispatch_wave` | `p_wave_id, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | 위와 동일 | `expected_version`은 웨이브 버전. 큐잉된 업무 오더를 순차 디스패치 시도 |
| `wms_retry_work_order_dispatch` | `p_work_order_id, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | 위와 동일 | `expected_version`은 업무 오더 버전. `QUEUED`만 허용 |
| `wms_cancel_work_order` | `p_work_order_id, p_actor_id, p_idempotency_key, p_expected_version, p_reason default null` | 위와 동일 | `DISPATCHED`면 연결된 설비 명령도 취소 시도 |
| `wms_get_work_order_status` | `p_tenant_id, p_warehouse_id, p_work_order_id default null` | 모든 테넌트/창고 멤버(읽기) | 업무 오더 + 연결된 설비 명령 상태 + 웨이브 정보를 조인한 조회 전용 함수 |

모든 쓰기 RPC는 성공 시 `{result: 'ok', document_id, status, version,
next_actions, warnings?}` 형태를 반환하고, 각각 `wms.audit_events`에
`entity_type in ('work_order', 'dispatch_wave')` 레코드를 남긴다. 가용 설비가
없어 디스패치를 시도했지만 `QUEUED`로 남는 경우, `result`는 여전히 `'ok'`이고
`warnings`에 `NO_EQUIPMENT_AVAILABLE` 같은 코드가 담긴다(오류가 아니라 정상
경로임을 반영).

### 완료 전파 메커니즘 (구현 검토용)

새 RPC가 아니라, `wms.equipment_commands`에 추가하는 트리거(D2)로 구현한다.
트리거는 `NEW.status in ('COMPLETED','FAILED')` 이고 `NEW.linked_entity_type =
'work_order'`일 때 `wms.work_orders`에서 `id = NEW.linked_entity_id`인
레코드를 찾아 `status`를 대응 값으로, `version`을 증가시키고,
`wms.audit_events`에 `command='wms_propagate_command_result'`,
`entity_type='work_order'` 레코드를 남긴다. 이 트리거는
`wms_wcs-equipment-control`의 마이그레이션이 먼저 적용된 뒤, 이 변경의
마이그레이션에서 `create trigger ... on wms.equipment_commands`로 추가한다 —
그 테이블의 원 소유 마이그레이션 파일 자체는 수정하지 않는다.

## 역할 모델

새 역할을 추가하지 않는다(D4). 기존 역할 재사용:

| 역할 | 이 계약에서의 권한 |
|---|---|
| `WMS_ADMIN` | 모든 쓰기 RPC 호출 가능 |
| `WAREHOUSE_MANAGER` | 웨이브 개설·릴리즈, 업무 오더 등록·재시도·취소 |
| `WCS_OPERATOR` | 웨이브 개설·릴리즈, 업무 오더 등록·재시도·취소 |
| `PROCESS_AGENT` | 웨이브 개설·릴리즈, 업무 오더 등록·재시도·취소(ProcessGPT 자동화 경로) |

## RLS 패턴

기존 테이블과 동일하게, 신규 2개 테이블 모두:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer` RPC를
  통해서만 이루어진다.

## 확장 지점 (후속 네 영역)

| 후속 영역 (가칭 spec ID) | 이 계약을 어떻게 확장하는가 |
|---|---|
| `wms_wcs-sortation-logic`(고속 분류 제어) | `work_order.command_type`/`command_payload`에 `DIVERT`, `SET_SPEED` 등을 채워 이 계약의 디스패치 경로를 그대로 사용한다. 새 테이블 불필요. |
| `wms_wcs-intelligent-routing`(지능형 라우팅/병목 해소) | 이 계약의 "가용 설비 선택" 단계를 대체하거나 앞단에 끼워 넣어(D5의 단순 규칙 대신) 실시간 처리량 기반 재라우팅을 적용한다. |
| `wms_wcs-sequential-dispatch`(서열 출고/지능형 적재) | `work_order.linked_entity_type`에 `'outbound_wave'` 같은 새 값을 추가하고, `command_payload`에 적재 순서 인덱스를 담아 이 계약의 Wave 큐잉·릴리즈를 그대로 재사용한다. |
| `wms_wes-digital-twin`(디지털 트윈/시뮬레이션) | `WCS_GATEWAY`로 인증하는 시뮬레이터가 `wms_wcs-equipment-control`의 결과 보고 RPC를 호출하면, 이 계약의 완료 전파 트리거가 자동으로 반응한다 — 이 계약을 수정할 필요가 없다. |

## 프론트엔드 확장 지점 (구현 아님, 위치만 기록)

- `/wes/work-orders` — 업무 오더 목록·상태·연결된 설비 명령을 보여주는 화면
  후보. `frontend/src/views/`에 `WorkOrderView.vue` 형태로 추가될 후보.
- `/wes/waves` — 웨이브 개설·업무 오더 편입 현황·릴리즈 버튼을 제공하는 화면
  후보.

이번 변경은 위 두 화면을 구현하지 않는다 — RPC/MCP 계약만 제공한다.

## Risks / Trade-offs

- **선행 변경(`wms_wcs-equipment-control`) 미구현에 대한 의존.** 이 설계는
  검증되지 않은 스키마 위에 쌓은 스펙이다. 완화책: 두 변경의 마이그레이션
  적용 순서를 tasks.md에 명시하고, 이 변경의 E2E는 선행 변경의 시뮬레이터
  스크립트를 재사용해 왕복 검증한다.
- **완료 전파 트리거가 다른 변경이 소유한 테이블에 얹힌다(D2).** 완화책:
  트리거 정의를 이 변경의 마이그레이션 파일에만 두고, `wms.equipment_commands`
  테이블 정의 자체는 건드리지 않는다 — 선행 변경이 나중에 그 테이블 구조를
  바꾸면 이 트리거도 함께 재검토해야 함을 tasks.md에 남긴다.
- **호출자 역할이 두 계약(이 계약과 `wms_wcs-equipment-control`)에서 정확히
  일치해야 한다(D3).** 완화책: 역할 집합을 설계 문서 두 곳 모두에 동일하게
  적어 drift를 방지하고, E2E에 "허용 역할로 호출 시 내부 디스패치까지
  성공"하는 케이스를 포함한다.
- **업무 오더 완료가 상위 WMS 엔티티 상태로 자동 반영되지 않는 것(Non-Goal)은
  의도적 경계지만, 실제로는 "그래서 누가 `wms_create_putaway_tasks`를
  호출하는가"라는 통합 공백을 남긴다.** 완화책: 이 공백을 감추지 않고
  tasks.md와 §5 카탈로그 갱신에 명시적으로 "미해결 통합 지점"으로 기록한다 —
  후속 변경(ProcessGPT 오케스트레이션 연동 또는 별도 통합 스펙)이 채워야
  한다.
