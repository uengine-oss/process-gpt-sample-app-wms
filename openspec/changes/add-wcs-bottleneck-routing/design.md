## Context

`add-wcs-equipment-control-contract`(capability `wms_wcs-equipment-control`,
아직 미구현)는 설비 등록, 명령 디스패치, 상태/이벤트 피드백, 장애 처리라는
WMS↔설비 소프트웨어 계약을 정의했다. `add-wes-material-flow-control`
(capability `wms_wes-material-flow-control`, 아직 미구현)는 그 위에서 WMS
작업 의도를 업무 오더로 등록하고, 적합한 가용 설비를 골라 명령을 디스패치하는
미들웨어를 정의했다 — 다만 그 설계 문서 D5는 "가용 설비 선택"을 "미종결
명령이 있으면 제외 + 최근 완료 건수가 적은 순"이라는 예방적 라운드로빈으로
한정하고, "병목이 이미 생긴 뒤 우회"하는 로직은 명시적으로 이 후속 스펙의
몫으로 남겼다.

`docs/04-wms-wcs-market-feature-catalog.md`가 정리한 현대무벡스의 실제 제품
스펙("설비 간 병목 현상 해소 알고리즘, 시간당 처리량 최적화", "설비 이상 시
실시간 장비 상태 분석, 작업 경로 재설정 또는 우회 경로를 자동 할당")은 이
설계가 무엇을 채워야 하는지 명확히 규정한다: 감지(병목 판정)와 반응(회피
라우팅)이다. 실제 벤더가 이를 어떻게 구현하는지는 공개되어 있지 않지만,
"고속 데이터 처리 기반 실시간 장비 트래픽 분석"이라는 표현으로 볼 때 상당한
수준의 실시간 최적화/예측 로직을 갖추고 있을 것으로 추정된다 — 이 샘플 앱은
그 수준의 알고리즘을 재현하지 않는다. 대신 **임계값 기반의, 설명 가능한
(explainable) 규칙**만 구현한다: 큐 길이와 최근 장애 빈도가 정해진 문턱값을
넘으면 병목으로 판정한다. 이는 정직한 스코프 축소다 — 실제 벤더 수준의
ML/최적화 알고리즘이 아니라는 점을 이 문서와 spec.md 양쪽에 명시한다.

### 정직한 전제 확인 (구현 상태와 의존성의 성격)

- **area1, area2 모두 아직 구현되지 않았다.** `supabase/migrations/`에 해당
  마이그레이션 파일이 없다. 이 설계가 참조하는 `wms.equipment`,
  `wms.equipment_commands`, `wms.equipment_faults`, `wms.work_orders` 등은
  각 스펙의 design.md에 있는 **검토용 후보**이며, 실제 DB에는 존재하지
  않는다.
- **이 변경의 실제 DB 의존성은 area1에만 있다.** 이 설계가 추가하는 뷰
  (`wms.wcs_equipment_load_snapshot`, `wms.wcs_equipment_bottleneck_status`)와
  내부 함수(`wms.wcs_select_available_equipment`)는 `wms.equipment`,
  `wms.equipment_commands`, `wms.equipment_faults`만 읽는다.
  `wms.work_orders`, `wms.dispatch_waves`는 전혀 참조하지 않는다 — 병목
  판정과 설비 선택은 순수하게 "설비" 도메인의 문제이지 "업무 오더" 도메인의
  문제가 아니기 때문이다. 따라서 이 변경의 마이그레이션은 area1의
  마이그레이션이 적용된 뒤라면 area2의 마이그레이션 적용 여부와 무관하게
  적용할 수 있다.
- **area2와의 연결은 스키마 의존성이 아니라 구현 통합 의존성이다.**
  `wms.wcs_select_available_equipment`가 실제로 신규 작업 디스패치에
  영향을 주려면, area2의 디스패치 RPC(`wms_create_work_order`(WAVELESS
  경로), `wms_release_dispatch_wave`, `wms_retry_work_order_dispatch`)가
  자신의 "가용 설비 선택 로직(3.5)"에서 인라인 쿼리 대신 이 함수를 호출하도록
  구현되어 있어야 한다. area2의 스펙 문서(`spec.md`)는 이 함수 호출을
  요구하지 않는다 — 오히려 area2의 스펙은 "후보가 여럿이면 최근 완료 건수가
  가장 적은 설비를 우선 선택해야 한다(SHOULD)"라고만 규정하므로, 이
  계약의 하드/소프트 필터가 그 SHOULD 규칙보다 먼저 적용되어도 area2의
  스펙 문구와 모순되지 않는다(아래 D5).

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블/뷰/함수/RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스,
동일한 RLS/RPC 봉투 관례를 그대로 확장한다.

## Goals / Non-Goals

**Goals:**

- area1의 사실 기록(명령 큐, 장애 이력)을 관찰해 설비별 부하/건강 신호를
  실시간으로 조회할 수 있는 계약.
- 큐 길이와 최근 장애 빈도라는 두 개의 설명 가능한 임계값으로 병목 설비를
  판정하는 규칙, 그리고 그 임계값을 설비 유형/창고별로 조정할 수 있는 정책.
- area2의 가용 설비 선택 로직이 병목 설비를 회피하도록 하는 명시적 확장
  지점(내부 함수) — area2의 스펙 문구를 바꾸지 않으면서.
- 운영자가 계획 정비 등의 이유로 병목 여부와 무관하게 특정 설비를 자동
  라우팅에서 강제로 제외/재포함할 수 있는 수동 개입 경로.
- 후속 두 영역(서열 출고/지능형 적재, 디지털 트윈/시뮬레이션)이 이 계약을
  다시 만들지 않고 그 위에 얹을 수 있는 확장 지점.

**Non-Goals:**

- 머신러닝 기반 예측, 실시간 최적화 알고리즘 — 이 계약은 임계값 비교만
  한다. 현대무벡스 등 실제 벤더가 쓸 것으로 추정되는 고급 알고리즘을
  재현하지 않는다.
- 컨베이어/슈트 물리적 토폴로지 그래프를 이용한 "경로 재설정"(카탈로그의
  "작업 경로 재설정") — 이 계약은 설비 A 대신 설비 B를 고르는 수준의
  "대상 재선택"만 다룬다. 컨베이어 분기점 단위의 물리적 경로 계산은 다루지
  않는다 — 그런 개념 자체가 이 저장소의 스키마에 없다(설비는 개별
  레코드일 뿐, 설비 간 연결 그래프가 없다).
- 처리량(Throughput) 이력 저장, 시간대별 트렌드 분석, 용량 계획 — 이
  계약의 신호는 항상 "지금 시점"의 라이브 조회이며 시계열 데이터를 쌓지
  않는다(D2).
- 설비별 평균 처리 지연시간(latency) 계산 — 시작/완료 이벤트를 명령
  단위로 짝짓는 로직은 복잡하고, 큐 길이와 장애 빈도만으로도 병목을 충분히
  설명 가능한 신호로 판단해 이번 변경에서 제외한다.
- 서열 출고 순서 계산, 다중 로봇 셀 팔레타이징 최적화 — 후속 스펙
  `wms_wcs-sequential-dispatch`(가칭, area5)에서 다룬다.
- 디지털 트윈 시뮬레이션 엔진 — 후속 스펙 `wms_wes-digital-twin`(가칭,
  area6)에서 다룬다.
- 임계값 정책의 자동 튜닝(과거 데이터 기반 threshold 학습) — 값은 사람이
  직접 설정한다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 부하/건강 신호는 테이블이 아니라 뷰로 구현한다

`wms.wcs_equipment_load_snapshot`, `wms.wcs_equipment_bottleneck_status`
둘 다 `create view`로 구현하고, 별도로 값을 저장하는 테이블이나 그 값을
갱신하는 트리거를 만들지 않는다. 이유:

1. area1의 `wms.equipment_commands`, `wms.equipment_faults`는 이미 사실을
   보존하는 원장성 테이블이다(상태 전이 시점이 `updated_at`/`created_at`에
   그대로 남는다). 뷰는 그 위에서 조회 시점마다 정확한 값을 다시 계산할 뿐,
   별도 사본을 만들지 않으므로 **데이터 드리프트가 구조적으로 불가능하다.**
2. 이 샘플 앱은 "지금 이 설비가 병목인가"라는 실시간 질문에만 답하면
   된다(Goals). 시계열 트렌드 저장은 Non-Goal이므로 값을 영속화할 이유가
   없다.
3. 테이블+트리거 방식을 택하면 area1이 소유한 `wms.equipment_commands`,
   `wms.equipment_faults`에 또 다른 `AFTER INSERT/UPDATE` 트리거를 얹어야
   한다(area3가 이미 같은 테이블에 트리거를 하나 얹고 있다 — D5 참고).
   트리거가 늘어날수록 "이 트리거가 실패하거나 순서가 꼬이면 신호가 실제
   상태와 어긋난다"는 이중 관리 위험이 커진다. 뷰는 그 위험이 없다.

트레이드오프: 뷰는 조회할 때마다 집계 쿼리를 다시 실행하므로, 설비 수와
명령 이력이 아주 커지면(수만 건 이상) 조회 비용이 늘어난다. 이 샘플 앱
(그린필드 데모) 규모에서는 무시할 만하다고 판단한다. 실제 프로덕션
규모라면 `materialized view` + 주기적 refresh, 또는 별도 집계 테이블 +
트리거로 전환하는 것을 고려해야 하며, 이는 이 설계가 명시적으로 남기는
후속 최적화 지점이다.

### D2. 병목 플래그는 저장된 상태가 아니라 매 조회 시 계산되는 값이다

"병목이다/아니다"를 `wms.equipment.status`처럼 별도 상태 컬럼에 저장하고
전이시키는 대신, `wms.wcs_equipment_bottleneck_status` 뷰가 조회 시점마다
임계값과 비교해 `is_bottleneck` 불리언을 계산한다. `BOTTLENECK_DETECTED`/
`BOTTLENECK_CLEARED` 같은 새 이벤트 타입이나 상태 기계를 만들지 않는다.
카탈로그의 "실시간 장비 상태 분석"이라는 표현과도 맞다 — 이 값은 항상
"지금" 기준이다.

트레이드오프: "이 설비가 언제부터 병목이었는가"라는 이력 질문에는 답할 수
없다(D1의 Non-Goal과 동일한 트레이드오프). 이력이 필요해지면 후속 변경이
`wms.equipment_status_events`에 새 `event_type`(예: `BOTTLENECK_FLAGGED`)을
추가하는 방식으로 확장할 수 있다 — 이번 변경은 그렇게 하지 않는다.

### D3. 병목 판정은 두 지표(큐 길이, 최근 장애 빈도)만 사용한다

`wms.wcs_equipment_bottleneck_status.is_bottleneck`은 다음 조건의 OR로만
계산한다:

- `queue_depth >= queue_depth_threshold` — 해당 설비에 대해 `PENDING`,
  `ACKNOWLEDGED`, `IN_PROGRESS` 상태인 `wms.equipment_commands`의 개수.
- `recent_fault_count >= fault_count_threshold` — 최근 고정 관찰 윈도우
  (30분, D6) 안에 그 설비에 대해 생성된 `wms.equipment_faults` 레코드 수
  (해소 여부 무관 — 최근에 장애가 잦았다는 사실 자체가 신호).

"설비 상태가 이미 `FAULT`인 경우"는 별도 조건으로 넣지 않는다 — area1의
상태 기계상 `FAULT` 설비는 area2의 후보 조건(`status='IDLE'`)에서 이미
걸러지므로, 병목 판정에 다시 넣는 것은 중복이다. 평균 처리 지연시간
(latency)은 Non-Goals에서 제외한 대로 포함하지 않는다. 이 두 지표만으로도
"몰리고 있다"(큐 길이)와 "불안정하다"(장애 빈도)라는 서로 다른 두 원인을
구분해서 보여줄 수 있어, 단순하면서도 설명 가능하다.

### D4. 임계값은 정책 테이블로 설비 유형별로 조정 가능하게 하되, 기본값을 코드에 내장한다

SRM과 AGV는 정상적인 큐 길이 범위가 다를 수 있다(SRM은 한 번에 하나씩
순차 처리, AGV는 여러 대가 병렬로 동작). `wms.wcs_routing_policies`는
`(warehouse_id, equipment_type)` 단위로 `queue_depth_threshold`,
`fault_count_threshold`를 저장한다. 운영자가 아무 정책도 등록하지 않은
설비 유형에 대해서는 시스템 기본값(`queue_depth_threshold=3`,
`fault_count_threshold=1`)을 사용한다 — 즉 정책 등록은 선택 사항이고,
빈 상태에서도 병목 판정 자체는 항상 동작한다.

### D5. area2의 가용 설비 선택 로직 소유권을 이 계약으로 옮긴다

area2 design.md는 이 확장을 두 가지 방식으로 예견했다 — "이 계약의 '가용
설비 선택' 단계를 **대체**하거나 **앞단에 끼워 넣어**". 이 설계는 "대체"를
선택한다: `wms.wcs_select_available_equipment(p_tenant_id, p_warehouse_id,
p_equipment_type, p_zone_code)` 함수가 area2의 기존 후보 조건(타입/구역
일치, `status='IDLE'`, 미종결 명령 없음)과 tie-break(최근 완료 건수 최소)를
**그대로 포함**하면서, 그 앞뒤로 이 계약의 필터를 추가한다:

1. **하드 필터(제외)**: `wms.wcs_routing_overrides`에 `status='ACTIVE'`인
   레코드가 있는 설비는 후보에서 완전히 제외한다 — 다른 후보가 전혀 없어도
   선택되지 않는다.
2. 남은 후보를 `wms.wcs_equipment_bottleneck_status.is_bottleneck` 기준으로
   두 그룹으로 나눈다.
3. **소프트 회피**: `is_bottleneck=false` 그룹이 비어 있지 않으면 그 그룹만
   최종 후보로 쓴다. 비어 있으면(즉 남은 후보가 전부 병목 플래그 상태라면)
   `is_bottleneck=true` 그룹으로 폴백한다 — 작업이 무한정 대기하는 것보다
   병목 설비라도 처리하는 편이 낫다는 판단이다.
4. 최종 후보 그룹 안에서 area2의 기존 tie-break(최근 시간 창 내 `COMPLETED`
   명령 수 최소)를 그대로 적용한다.

이렇게 하면 "대체"라고 부르지만 실제로는 area2의 정책을 감싸는 것에
가깝다 — area2의 스펙 문서가 규정한 후보 조건과 SHOULD tie-break는 최종
후보 그룹 안에서 문자 그대로 유지된다. 따라서 area2의 `spec.md`를 수정할
필요가 없다(Modified Capabilities 없음).

**대안으로 고려했으나 기각한 것**: "이 함수를 만들지 않고, area2의
디스패치 RPC 안에 이 계약의 뷰를 직접 조인하는 방식"도 가능했다. 하지만
그러면 병목 회피 로직이 area2의 여러 RPC(`wms_create_work_order`,
`wms_release_dispatch_wave`, `wms_retry_work_order_dispatch`)에 각각
중복 작성되고, 이 계약이 판정 규칙을 바꿀 때(예: D3의 지표 추가) area2의
세 RPC를 모두 찾아 고쳐야 한다. 단일 함수로 캡슐화하면 이 계약 하나만
바꾸면 된다 — "don't silently duplicate area2's dispatch RPCs"라는 원칙과도
일치한다(이 함수는 새 dispatch RPC가 아니라 area2가 이미 갖고 있던 선택
단계의 내부 구현일 뿐이다).

### D6. 관찰 윈도우는 30분으로 고정하고, 설정 가능한 파라미터로 노출하지 않는다

`recent_fault_count`의 관찰 윈도우를 정책 테이블의 컬럼으로 두는 것도
고려했으나, 임계값(threshold)만 조정 가능하게 하고 윈도우 길이는 뷰 정의에
고정 상수(`interval '30 minutes'`)로 박아 설계를 단순화했다. 실제 벤더는
이 윈도우 자체를 튜닝 가능한 설정으로 제공할 가능성이 높지만, 이 샘플
앱에서는 "임계값 튜닝"과 "윈도우 튜닝"을 동시에 노출하면 정책 테이블의
컬럼과 검증 로직이 늘어나는 데 비해 데모 가치가 낮다고 판단했다. 윈도우
조정이 필요해지면 `wms.wcs_routing_policies`에 컬럼을 추가하는 것으로
확장 가능하다(하위 호환 마이그레이션).

## 데이터 모델 (검토용 후보)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은 구현 단계에서
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`은 수정하지 않으며, `wms_wcs-equipment-control`
> (area1)이 구현된 뒤에만 적용할 수 있다.

### `wms.wcs_routing_policies` — 병목 판정 임계값 정책

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` | `uuid` | FK `wms.tenants` |
| `warehouse_id` | `uuid` | FK `wms.warehouses` |
| `equipment_type` | `text` | `SRM \| CONVEYOR \| SORTER \| AGV \| AMR \| ROBOT_CELL`(area1과 동일 값 집합) |
| `queue_depth_threshold` | `int` | 병목 판정 큐 길이 임계값, `> 0` |
| `fault_count_threshold` | `int` | 병목 판정 최근 장애 건수 임계값, `> 0` |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

`unique (warehouse_id, equipment_type)` — 설비 유형별로 하나의 정책만
존재한다.

### `wms.wcs_routing_overrides` — 수동 라우팅 제외

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `equipment_id` | `uuid` | FK `wms.equipment`(area1) |
| `reason` | `text` | 제외 사유(예: `'계획 정비'`), 필수 |
| `status` | `text` | `ACTIVE \| CLEARED` |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `cleared_by` / `cleared_at` | `uuid` / `timestamptz` | nullable, `CLEARED` 전이 시 채움 |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

설비당 동시에 `ACTIVE`인 제외 레코드는 하나만 허용한다(부분 유니크 인덱스,
`status='ACTIVE'`인 행에 대해서만 `equipment_id` 유니크).

### `wms.wcs_equipment_load_snapshot` — 실시간 부하 신호 (뷰)

area1의 `wms.equipment`, `wms.equipment_commands`, `wms.equipment_faults`를
조인해 설비별로 다음을 계산한다(테이블 아님, D1):

| 컬럼 | 설명 |
|---|---|
| `equipment_id` / `tenant_id` / `warehouse_id` / `equipment_type` / `zone_code` / `status` | area1의 `wms.equipment`에서 그대로 |
| `queue_depth` | 그 설비에 대해 `status in ('PENDING','ACKNOWLEDGED','IN_PROGRESS')`인 `wms.equipment_commands` 개수 |
| `recent_completed_count` | 최근 30분 내 `updated_at`을 가진 `status='COMPLETED'` 명령 개수(정보 제공용 — area2의 기존 tie-break와 같은 지표를 재사용, 병목 판정에는 쓰지 않음) |
| `recent_fault_count` | 최근 30분 내 `created_at`을 가진 `wms.equipment_faults` 개수(해소 여부 무관) |

### `wms.wcs_equipment_bottleneck_status` — 병목 판정 결과 (뷰)

`wms.wcs_equipment_load_snapshot`을 `wms.wcs_routing_policies`와
`(warehouse_id, equipment_type)`로 좌측 조인하고, 정책이 없으면 D4의
시스템 기본값으로 대체한 뒤 다음을 계산한다:

| 컬럼 | 설명 |
|---|---|
| (load_snapshot의 모든 컬럼) | |
| `resolved_queue_depth_threshold` / `resolved_fault_count_threshold` | 적용된 임계값(정책 또는 기본값) |
| `is_bottleneck` | D3의 OR 조건 계산 결과 |
| `bottleneck_reasons` | `text[]`, `'QUEUE_DEPTH_EXCEEDED'`/`'FAULT_FREQUENCY_EXCEEDED'` 중 해당하는 값(둘 다 해당하면 둘 다 포함) |
| `is_excluded` | `wms.wcs_routing_overrides`에 `status='ACTIVE'`인 레코드 존재 여부 |

## 함수 계약 — 가용 설비 선택 훅 (검토용, 비-MCP)

```
wms.wcs_select_available_equipment(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_equipment_type text,
  p_zone_code text
) returns uuid  -- 선택된 equipment_id, 후보가 전혀 없으면 null
```

`language plpgsql security definer set search_path = wms, public`으로
정의한다. area2의 디스패치 RPC(`wms_create_work_order`,
`wms_release_dispatch_wave`, `wms_retry_work_order_dispatch`)가 내부에서
호출한다(D5). `authenticated`에는 `EXECUTE` 권한을 부여하지 않는다 — area2의
`SECURITY DEFINER` RPC 안에서 함수 소유자 권한으로 호출되므로 직접 grant가
필요 없다. `mcp/wms_mcp/mcp_server.py`에 별도 도구로 노출하지 않는다.

## RPC 계약 (검토용 시그니처 초안)

모든 RPC는 기존과 동일하게 `language plpgsql security definer set search_path =
wms, public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only)를 따른다.

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_register_wcs_routing_policy` | `p_tenant_id, p_warehouse_id, p_equipment_type, p_queue_depth_threshold, p_fault_count_threshold, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | 이미 정책이 있는 `(warehouse_id, equipment_type)`이면 `INVALID:` |
| `wms_update_wcs_routing_policy` | `p_policy_id, p_queue_depth_threshold default null, p_fault_count_threshold default null, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | `expected_version`은 정책 버전 |
| `wms_exclude_equipment_from_routing` | `p_equipment_id, p_reason, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` | 이미 `ACTIVE` 제외가 있으면 `INVALID:` |
| `wms_clear_equipment_routing_exclusion` | `p_override_id, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` | 이미 `CLEARED`면 `INVALID:` |
| `wms_get_equipment_routing_status` | `p_tenant_id, p_warehouse_id, p_equipment_id default null` | 모든 테넌트/창고 멤버(읽기) | `wms.wcs_equipment_bottleneck_status` + 활성 제외 정보를 조인한 조회 전용 함수 |

모든 쓰기 RPC는 성공 시 `{result: 'ok', document_id, status, version,
next_actions, warnings?}` 형태를 반환하고, 각각 `wms.audit_events`에
`entity_type in ('wcs_routing_policy', 'wcs_routing_override')` 레코드를
남긴다.

## 역할 모델

새 역할을 추가하지 않는다. 기존 역할 재사용:

| 역할 | 이 계약에서의 권한 |
|---|---|
| `WMS_ADMIN` | 모든 쓰기 RPC 호출 가능 |
| `WAREHOUSE_MANAGER` | 정책 등록·갱신, 강제 제외·해제 |
| `WCS_OPERATOR` | 강제 제외·해제(정책 등록/갱신은 불가 — 임계값 튜닝은 운영 관리자 권한으로 제한) |
| (모든 멤버) | `wms_get_equipment_routing_status` 읽기 |

`PROCESS_AGENT`는 이 계약의 쓰기 RPC 호출 목록에 포함하지 않는다 — 병목
임계값 조정과 설비 강제 제외는 사람의 운영 판단이 필요한 영역이라고
판단했다(장애 해소가 `WCS_OPERATOR`/사람 전용인 것과 같은 원칙, area1 D5).

## RLS 패턴

기존 테이블과 동일하게, 신규 2개 테이블 모두:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer` RPC를
  통해서만 이루어진다.
- 뷰 2개는 기반 테이블(`wms.equipment*`, `wms.wcs_routing_policies`)의 RLS를
  그대로 상속받도록 `security invoker`로 정의한다(뷰 자체에 RLS를 별도로
  걸지 않는다 — 기반 테이블의 정책이 이미 창고 스코프를 강제한다).

## 확장 지점 (후속 두 영역)

| 후속 영역 (가칭 spec ID) | 이 계약을 어떻게 확장하는가 |
|---|---|
| `wms_wcs-sequential-dispatch`(서열 출고/지능형 적재, area5) | `ROBOT_CELL` 대상 디스패치도 결국 `wms.wcs_select_available_equipment`를 거치게 되면 병목 회피가 자동으로 적용된다. 서열 적재 순서 계산 자체는 이 계약과 무관하며 별도 로직으로 얹힌다. |
| `wms_wes-digital-twin`(디지털 트윈/시뮬레이션, area6) | 시뮬레이터가 `WCS_GATEWAY`로 명령 결과/장애를 보고하면, 이 계약의 뷰가 그 값을 그대로 반영해 시뮬레이션 시나리오에서도 병목 판정이 실시간으로 동작한다 — 이 계약을 수정할 필요가 없다. 또한 시뮬레이션 환경에서 D1의 뷰 방식 성능 한계(대량 이력)를 실제로 관찰·검증할 수 있는 첫 기회가 된다. |

## 프론트엔드 확장 지점 (구현 아님, 위치만 기록)

- `/wcs/routing` — 설비별 큐 길이·최근 장애 건수·병목 플래그·강제 제외
  상태를 한 화면에서 보여주고, 강제 제외/해제 버튼을 제공하는 화면 후보.
  `frontend/src/views/`에 `WcsRoutingView.vue` 형태로 추가될 후보. area1의
  `/wcs/monitor`와 함께 배치될 수 있다.

이번 변경은 이 화면을 구현하지 않는다 — RPC/MCP 계약만 제공한다.

## Risks / Trade-offs

- **선행 변경 두 개(area1, area2) 모두 미구현에 대한 의존.** 완화책:
  이 변경의 실제 마이그레이션 의존성은 area1뿐임을 명시하고(Context
  절), area2와의 통합은 별도 조정 작업(tasks.md)으로 분리해 area1만
  구현된 상태에서도 이 변경의 스키마·읽기 기능은 독립적으로 검증 가능하게
  한다.
- **뷰 기반 실시간 집계는 데이터 규모가 커지면 느려질 수 있다(D1).**
  완화책: 이 샘플 앱 규모에서는 무시할 만하다고 명시하고, materialized
  view 전환을 후속 최적화 지점으로 문서에 남긴다.
- **병목 판정이 이력을 남기지 않아 "언제부터 병목이었는가"를 감사할 수
  없다(D2).** 완화책: 필요해지면 `wms.equipment_status_events`에 새
  event_type을 추가하는 확장 경로를 design.md에 남긴다 — 이번 변경은
  하지 않는다.
- **area2의 후보 선택 함수 호출 여부가 이 변경만으로는 강제되지 않는다.**
  `wms.wcs_select_available_equipment`를 만들어도 area2의 구현이 실제로
  그 함수를 호출하지 않으면 병목 회피는 동작하지 않는다. 완화책: tasks.md에
  area2 구현과의 통합 확인 작업을 명시적으로 포함하고, E2E에 "강제 제외된
  설비가 유일한 후보일 때 업무 오더가 QUEUED로 남는지"를 area2의 실제
  디스패치 경로로 왕복 검증하는 시나리오를 둔다 — 함수 존재만으로 완료
  처리하지 않는다.
- **하드 제외(override)와 소프트 회피(bottleneck)를 다르게 취급하는 것은
  암묵적 판단이다** — 카탈로그 문구("우회 경로를 자동 할당")는 두 개념을
  구분하지 않는다. 완화책: 이 판단의 근거(강제 제외=사람의 명시적 의도로
  절대 배정 금지, 병목=선호도 낮춤이지 금지가 아님, 작업이 무기한 대기하는
  것을 막기 위한 폴백)를 D5에 명시적으로 적었고, spec.md의 시나리오로
  그 차이를 검증 가능하게 했다.
