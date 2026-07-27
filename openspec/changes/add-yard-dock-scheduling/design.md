## Context

이 저장소의 `wms` 스키마(`supabase/migrations/20260726_wms_core_schema.sql`)는
구매→입고→검수→적치라는 문서 중심 업무만 모델링한다. `wms.receipts`는
`status`가 `EXPECTED -> ARRIVED -> QC_PENDING -> QC_COMPLETED ->
PUTAWAY_PENDING -> PUTAWAY_COMPLETED`로 전이하고, `wms_register_arrival` RPC가
`EXPECTED -> ARRIVED` 전이를 담당한다. 이 RPC는 도크나 예약 시간창이라는 개념을
전혀 모른다 — 그냥 상태만 뒤집는다.

`docs/04-wms-wcs-market-feature-catalog.md` §2.1은 "야드 및 도크 관리"를
"입출고 차량 스케줄링(Dock Appointment Scheduling)"과 "야드 내 차량/화물 위치
추적" 두 세부 기능으로 정리하고, SAP EWM 절은 "Dock Appointment Scheduling"을
EWM의 부속 기능 중 하나로 명시한다. 동시에 main repo
`openspec/changes/supabase-wms-erp-replacement/design.md` §7.2는 원래 목표
위치 모델에 `warehouses, zones, locations, docks`를 나열했지만, 이 저장소의
실제 구현은 `wms.warehouses`만 만들고 zones/locations/docks는 만들지 않았다
(직접 확인: `supabase/migrations/20260726_wms_core_schema.sql`에 `create table
wms.warehouses`는 있으나 `zones`/`locations`/`docks` 테이블은 없다). 이 변경은
그 격차 중 도크 부분을 메운다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블과 RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

이 영역은 area1~6(WCS/WES 체인, `wms_wcs-equipment-control` 등)과 독립적이다.
`wms.equipment`, `wms.equipment_commands` 같은 설비 개념을 참조하지 않으며,
그런 참조가 없는 것이 의도된 설계다 — 도크는 "차량이 접안하는 물리적 게이트"를
관리하는 마스터데이터/입고 도메인 개념이지, 자동화 설비가 아니다.

## Goals / Non-Goals

**Goals:**

- 창고별 도크 레지스트리(`wms.docks`) — 최소 필드(코드, 이름, 상태)를 가진
  마스터데이터.
- 입고 PO에 연결된 도크 예약(`wms.dock_appointments`) — 특정 도크, 특정
  시간창(`scheduled_start`, `scheduled_end`)을 가진 예약 계약.
- 동일 도크의 겹치는 시간창 이중 예약을 DB 레벨에서 원천 차단하는 제약.
- 차량의 야드 체크인(야드 진입, 도킹 전) → 도킹(도크 점유 시작) → 출차(도크
  점유 해제)라는 이산 상태 전이 RPC.
- 도크 스케줄을 조회해 이중 예약 여부를 사람이 미리 확인할 수 있는 계약.
- 기존 `wms_register_arrival`과의 명시적 관계 정의(D2) — 두 계약이 서로를
  깨뜨리지 않고 공존하는 방법.
- 후속 확장(출고측 도크 예약, 실제 프론트엔드 도크 스케줄 화면)이 이 계약을
  다시 만들지 않고 얹을 수 있는 확장 지점.

**Non-Goals:**

- **실시간 GPS/RTLS 기반 연속 위치 추적.** 카탈로그의 "야드 내 차량/화물 위치
  추적"을 문자 그대로 만족시키려면 실시간 좌표 스트림이 필요하지만, 이는
  IoT/하드웨어 영역이며 소프트웨어 샘플 앱의 범위를 넘는다. 이 계약은 "체크인/
  도킹/출차"라는 이산 상태 전이만 다룬다 — "지금 몇 시 몇 분에 야드 어느
  좌표에 있는가"는 답하지 않는다.
- **출고측 도크 예약의 완전한 구현.** 이 저장소에는 정식 출고(outbound) 스키마가
  아직 병합되어 있지 않다(`add-wcs-sequential-dispatch`가 `wms.outbound_orders`를
  제안했으나 아직 이 변경 작성 시점 기준 별도 change로 진행 중이며 메인
  스키마에 병합되지 않았다). 이 계약은 출고 예약을 위한 **느슨한 확장 지점**
  (`appointment_type='OUTBOUND'` + `linked_entity_type`/`linked_entity_id`,
  D3)만 마련하고, 실제 출고 PO 개념에 대한 하드 FK나 검증 로직은 만들지
  않는다.
- **`wms_register_arrival`의 시그니처·동작 변경.** D2에서 다루듯 이 계약은
  기존 RPC를 감싸거나 대체하지 않는다.
- **적치 위치(zones/locations) 전체 위치 모델 완성.** main repo 목표 모델의
  `zones`, `locations`는 이 변경의 범위가 아니다 — `docks`만 다룬다.
- **예약 자동 재조정(rescheduling) 최적화, 도크 배정 알고리즘.** 어느 예약을
  어느 도크에 배정할지는 호출자(운영자)가 결정한다 — 이 계약은 그 결정을
  검증·저장·이중예약 차단할 뿐, 최적 도크를 추천하지 않는다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 이중 예약 방지는 애플리케이션 레벨 락이 아니라 Postgres
`EXCLUDE USING gist` 제약으로 구현한다

**선택한 방식:** `wms.dock_appointments`에 `during tstzrange` 생성 컬럼을
추가하고, `EXCLUDE USING gist (dock_id WITH =, during WITH &&) WHERE (status
IN ('SCHEDULED','CHECKED_IN','AT_DOCK'))` 제약을 건다(`btree_gist` extension
필요, `dock_id`의 `=` 비교를 GiST 인덱스에서 쓰기 위함).

**검토했지만 기각한 대안:** RPC 안에서 `SELECT ... FOR UPDATE`로 같은 도크의
기존 예약을 잠그고 겹침 여부를 애플리케이션 코드로 확인하는 방식.

**기각 이유:** 새로 삽입되는 예약은 아직 존재하지 않는 행이므로 "행 잠금"으로
막을 대상이 없다 — 두 개의 동시 트랜잭션이 각각 "이 시간창은 비어 있다"를
확인한 뒤 둘 다 삽입하면(고전적인 phantom-row race), 애플리케이션 레벨 체크만
으로는 `SERIALIZABLE` 격리 수준이나 별도의 advisory lock 없이는 이중 예약을
막을 수 없다. `SERIALIZABLE`은 이 저장소의 다른 RPC가 쓰지 않는 격리 수준을
이 계약만을 위해 도입해야 하고, advisory lock은 "락 키를 어떻게 정할지"를
수작업으로 관리해야 하는 별도의 복잡성을 만든다. 반면 `EXCLUDE` 제약은 삽입/
갱신 시점에 스토리지 엔진이 원자적으로 겹침을 검사하므로 기본 `READ
COMMITTED` 격리 수준에서도 경쟁 조건이 없다. 이 저장소는 이미 `CHECK`,
`UNIQUE` 같은 DB 레벨 불변식을 애플리케이션 검증보다 우선하는 관례를 갖고
있다(`purchase_orders.qty > 0`, `equipment.(warehouse_id, equipment_code)
unique` 등) — `EXCLUDE`는 그 관례의 시간 범위 버전일 뿐이다.

**부수 효과:** RPC(`wms_schedule_dock_appointment`)는 제약 위반
(`exclusion_violation`, SQLSTATE `23P01`)을 캐치해 `CONFLICT:` 접두 예외로
변환해야 한다 — 호출자 입장에서는 `expected_version` 불일치와 동일한 종류의
오류(409에 대응)로 다뤄진다.

### D2. 도크 체크인/도킹/출차는 `wms_register_arrival`을 대체하지 않고,
그보다 앞서 일어나는 독립적이고 직교(orthogonal)한 이벤트로 설계한다

이 계약이 다루는 대상은 "차량/트레일러가 야드와 도크에서 겪는 물리적 여정"이고,
`wms_register_arrival`이 다루는 대상은 "특정 PO의 화물이 검수 대기 상태에
도달했다"는 것이다. 둘은 서로 다른 애그리게잇이다 — 하나의 차량 여정 안에
여러 PO의 화물이 섞여 있을 수 있고(한 트럭이 여러 PO를 나눠 싣고 오는 경우),
반대로 도크 예약 없이도 화물이 접수될 수 있다(이 저장소는 그린필드 데모이므로
기존 시나리오/시드 데이터가 도크 예약 없이 `wms_register_arrival`을 호출하는
경로를 계속 지원해야 한다).

**결정: 도킹(`wms_dock_vehicle`, 도크 점유 시작)은 `wms_register_arrival`보다
먼저 일어나는 것이 일반적인 실제 흐름이지만, 이 계약은 그 순서를 강제하지
않는다.** 즉:

- `wms_register_arrival`은 시그니처·전제조건을 변경하지 않는다 — 도크 예약이
  존재하는지, 어떤 상태인지 검사하지 않는다.
- 도크 예약(`wms.dock_appointments`)이 PO(`po_id`)를 참조할 수는 있지만, 그
  참조는 순수 정보 연결(같은 PO가 어느 도크·시간창에 배정됐는지 조회하기
  위함)일 뿐, `wms_register_arrival` 호출을 막거나 자동으로 트리거하지
  않는다.
- 두 RPC 다 각자의 애그리게잇(예약 vs. receipt)에만 낙관적 동시성
  (`expected_version`)을 적용한다 — 서로의 버전을 검증하지 않는다.

**기각한 대안 1(대체):** 도킹 이벤트가 자동으로 `wms_register_arrival`을
호출하게 만드는 방식. 기각 이유 — 기존 RPC의 호출 계약(어떤 역할이, 어떤
전제조건에서 호출하는지)을 이 변경이 암묵적으로 바꾸게 되어, 도크 예약 없이
동작하던 기존 시나리오/시드 데이터가 깨질 위험이 있다.

**기각한 대안 2(하드 선행조건):** `wms_register_arrival`이 호출되기 전에
반드시 `AT_DOCK` 상태의 예약이 있어야 한다고 강제하는 방식. 기각 이유 — 한
차량이 여러 PO를 나눠 싣고 오는 경우 "receipt 1건 : 예약 1건"의 1:1 관계를
강제할 수 없고, 이 저장소의 기존 데모 시나리오(도크 없이 입하)를 깨뜨린다.

**채택한 결론:** 직교(orthogonal) 관계. 운영 절차 문서(design.md 밖, 향후
프론트엔드/매뉴얼)에서 "권장 순서: 체크인 → 도킹(도크 점유) → (하역 진행 중)
`wms_register_arrival` 호출 → 출차"를 안내할 수는 있지만, 이는 사람이 따르는
운영 절차이지 DB가 강제하는 제약이 아니다. 향후 두 계약을 실제로 연결하고
싶다면(예: 도킹 시 자동으로 연결된 receipt를 조회해 상태를 확인하는 조회
전용 뷰), 그것은 이 계약을 깨지 않는 후속 확장으로 남긴다.

### D3. `wms.dock_appointments`는 입고(PO)를 필수 참조로 갖되, 출고 예약은
느슨한 참조(`linked_entity_type`/`linked_entity_id`)로만 확장 지점을 남긴다

이 저장소는 정식 출고 스키마가 없다(`add-wcs-sequential-dispatch`가
`wms.outbound_orders`를 제안했지만 별도 change로 진행 중이며 아직 메인
스키마에 병합되지 않았다). 그렇다고 이 계약이 입고만 영원히 다룬다고 못박으면
후속 변경이 다시 테이블을 만들어야 한다. 그래서:

- `appointment_type text check (appointment_type in ('INBOUND','OUTBOUND'))`로
  방향을 구분한다.
- `po_id uuid references wms.purchase_orders(id)`는 `appointment_type =
  'INBOUND'`일 때 필수(체크 제약)다 — 이것이 이 변경의 필수 최소 스코프다.
- `linked_entity_type text` + `linked_entity_id uuid`(하드 FK 없음, area1
  `wms.equipment_commands`가 이미 쓰는 것과 동일한 느슨한 참조 패턴)를 추가해
  `appointment_type = 'OUTBOUND'`일 때 향후 `wms.outbound_orders.id` 같은 값을
  담을 수 있게 여지만 남긴다. 이번 변경은 그 값을 검증하거나 활용하는 로직을
  구현하지 않는다 — 컬럼만 마련한다.

### D4. 도크의 `status`는 예약 상태 전이에서 파생되고, 별도 RPC는 정비
목적의 `CLOSED` 전환만 다룬다

도크는 3가지 상태(`AVAILABLE`, `OCCUPIED`, `CLOSED`)를 갖는다.
`OCCUPIED`/`AVAILABLE` 전이는 사람이 직접 호출하지 않는다 — 차량 상태 전이
RPC(`wms_dock_vehicle`, `wms_depart_vehicle`)가 부수 효과로 도크 상태를
파생시킨다:

- `wms_dock_vehicle`(예약이 `CHECKED_IN -> AT_DOCK`으로 전이): 대상 도크
  상태를 `OCCUPIED`로 바꾼다. 도크가 이미 `OCCUPIED`거나 `CLOSED`면 거부한다.
- `wms_depart_vehicle`(예약이 `AT_DOCK -> DEPARTED`로 전이): 대상 도크 상태를
  `AVAILABLE`로 되돌린다(도크가 그 사이 관리자에 의해 `CLOSED`로 바뀌지
  않았다면).

반대로 `wms_set_dock_status`(정비용 `AVAILABLE <-> CLOSED` 전환)는 사람
(`WMS_ADMIN`, `WAREHOUSE_MANAGER`)만 호출하며, 도크가 `OCCUPIED`인 동안은
`CLOSED`로 전환할 수 없다(먼저 출차 처리해야 함) — 점유 중인 도크를 갑자기
닫아 진행 중인 하역을 유령 상태로 만들지 않기 위함이다.

### D5. 새 역할을 만들지 않고 기존 역할을 재사용한다

area1(`wms_wcs-equipment-control`)은 설비 게이트웨이를 위해 `WCS_GATEWAY`,
`WCS_OPERATOR`라는 전용 역할을 새로 도입했다 — 설비는 소프트웨어/하드웨어가
WMS에 직접 상태를 보고하기 때문이다. 이 계약은 다르다: 도크 예약을 만들고
차량 체크인/도킹/출차를 기록하는 주체는 항상 **사람**(입고 담당자, 창고
관리자) 또는 사람을 대신하는 ProcessGPT 에이전트다. 따라서 새 역할을 만들지
않고 기존 역할을 그대로 재사용한다:

- `WMS_ADMIN`, `WAREHOUSE_MANAGER`(area1에서 이미 도입된 역할, `wms.memberships.role`이
  자유 텍스트이므로 재사용에 마이그레이션 불필요): 도크 등록, 도크 정비
  상태 전환.
- `INBOUND_OPERATOR`: 도크 예약 생성/취소, 차량 체크인/도킹/출차 — 기존
  `wms_register_arrival`/`wms_receive`를 호출하는 것과 같은 역할군이 자연스럽게
  이 계약도 함께 다룬다.
- `PROCESS_AGENT`: 도크 예약 생성/취소, 스케줄 조회만 허용한다 — 차량의
  물리적 체크인/도킹/출차는 실제 사람(운전기사·게이트 요원)의 관찰을 대리
  보고하는 행위이므로, 에이전트가 실제 차량 움직임 없이 상태를 조작하는
  것을 막기 위해 이 세 RPC는 `PROCESS_AGENT`에게 허용하지 않는다.

## Data Model

### `wms.docks` (신규 — 창고별 도크 레지스트리)

| 컬럼 | 설명 |
|---|---|
| `id` | PK |
| `tenant_id`, `warehouse_id` | 기존 관례와 동일한 스코프 FK |
| `code` | 창고 내 고유 도크 코드(`unique (warehouse_id, code)`) |
| `name` | 표시명 |
| `status` | `AVAILABLE \| OCCUPIED \| CLOSED` |
| `version` | 낙관적 동시성 |
| `created_at`, `updated_at` | 감사 |

### `wms.dock_appointments` (신규 — 도크 예약)

| 컬럼 | 설명 |
|---|---|
| `id` | PK |
| `tenant_id`, `warehouse_id` | 스코프 FK |
| `dock_id` | 예약된 특정 도크(FK `wms.docks`) |
| `appointment_type` | `INBOUND \| OUTBOUND` |
| `po_id` | `appointment_type='INBOUND'`일 때 필수(FK `wms.purchase_orders`) |
| `linked_entity_type`, `linked_entity_id` | `appointment_type='OUTBOUND'`용 느슨한 참조(하드 FK 없음, D3) |
| `carrier_name`, `vehicle_plate_no` | 예약/체크인 시점에 기록되는 차량 식별 정보(nullable, 체크인 시 채워질 수도 있음) |
| `scheduled_start`, `scheduled_end` | 예약 시간창(`scheduled_end > scheduled_start` 체크) |
| `during` | `tstzrange(scheduled_start, scheduled_end, '[)')` 생성 컬럼(GiST 제약용) |
| `status` | `SCHEDULED \| CHECKED_IN \| AT_DOCK \| DEPARTED \| CANCELLED` |
| `version` | 낙관적 동시성 |
| `correlation_id`, `created_by`, `created_at`, `updated_at` | 기존 관례와 동일 |

제약: `exclude using gist (dock_id with =, during with &&) where (status in
('SCHEDULED','CHECKED_IN','AT_DOCK'))` — D1.

### 상태 기계

```text
dock_appointments.status:
  SCHEDULED -> CHECKED_IN -> AT_DOCK -> DEPARTED
  SCHEDULED -> CANCELLED
  CHECKED_IN -> CANCELLED

docks.status:
  AVAILABLE <-> CLOSED   (사람이 수동 전환, wms_set_dock_status)
  AVAILABLE -> OCCUPIED  (wms_dock_vehicle의 부수 효과)
  OCCUPIED -> AVAILABLE  (wms_depart_vehicle의 부수 효과)
```

## RPC 계약 (기존과 동일한 envelope: `tenant_id, warehouse_id, actor_id,
idempotency_key, expected_version, correlation_id` 입력 / `{result,
document_id, status, version, next_actions, warnings}` 형태의 출력, 오류는
`CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 `RAISE EXCEPTION`)

| RPC | 역할 | 설명 |
|---|---|---|
| `wms.wms_register_dock` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | 도크 등록(`code`, `name`), 초기 상태 `AVAILABLE` |
| `wms.wms_set_dock_status` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | `AVAILABLE <-> CLOSED` 수동 전환, `OCCUPIED` 중에는 `CLOSED` 거부 |
| `wms.wms_schedule_dock_appointment` | `INBOUND_OPERATOR`, `WMS_ADMIN`, `PROCESS_AGENT` | 도크+시간창 예약 생성, `SCHEDULED` 상태로 시작, 겹치면 `CONFLICT:`(D1) |
| `wms.wms_cancel_dock_appointment` | `INBOUND_OPERATOR`, `WMS_ADMIN`, `PROCESS_AGENT` | `SCHEDULED`/`CHECKED_IN` 예약을 `CANCELLED`로 |
| `wms.wms_check_in_vehicle` | `INBOUND_OPERATOR`, `WMS_ADMIN` | `SCHEDULED -> CHECKED_IN`(야드 진입, 도킹 전) |
| `wms.wms_dock_vehicle` | `INBOUND_OPERATOR`, `WMS_ADMIN` | `CHECKED_IN -> AT_DOCK`, 도크 상태 `OCCUPIED`로(D4) |
| `wms.wms_depart_vehicle` | `INBOUND_OPERATOR`, `WMS_ADMIN` | `AT_DOCK -> DEPARTED`, 도크 상태 `AVAILABLE`로(D4) |
| `wms.wms_get_dock_schedule` | 창고 스코프를 가진 모든 인증 사용자(읽기 전용) | 창고·기간 기준 도크별 예약 목록 조회(이중 예약 여부를 사람이 미리 확인) |

`wms_register_arrival`은 이 표에 없다 — 시그니처도 동작도 변경하지 않는다(D2).

## 확장 지점

- **프론트엔드**: `frontend/src/router/index.ts`에 `/inbound/dock-schedule`
  (도크별 캘린더/타임라인 뷰) 라우트를 추가하는 것은 이 변경에 포함하지
  않는다 — `wms_get_dock_schedule`을 소비하는 후속 작업으로 남긴다.
- **출고측 도크 예약**: `add-wcs-sequential-dispatch`의 `wms.outbound_orders`가
  실제로 메인 스키마에 병합되면, `linked_entity_type='outbound_order'` +
  `linked_entity_id`로 이 계약을 그대로 재사용할 수 있다(D3) — 새 예약
  테이블을 만들 필요가 없다.
- **`wms_register_arrival`과의 조회 전용 연결**: 향후 도킹 시점에 연결된
  `po_id`의 receipt 상태를 함께 보여주는 조회 전용 뷰(`wms.dock_schedule_v`
  같은)를 추가하는 것은 이 계약을 깨지 않는 순수 추가로 가능하다(D2가 막는
  것은 "쓰기 방향 결합"이지 "읽기 조인"이 아니다).
- **실시간 위치 추적(RTLS/GPS)**: 이 계약의 Non-Goals다. 만약 향후 실제 RTLS
  하드웨어를 연동한다면, 그 위치 스트림은 별도 계약(예: 시계열 위치 테이블 +
  이 계약의 `dock_appointments.id`를 참조하는 느슨한 링크)으로 얹는 것이
  맞다 — 이 계약의 상태 기계를 연속 좌표로 확장하지 않는다.
