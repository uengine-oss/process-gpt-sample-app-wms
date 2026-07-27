## Context

`add-wcs-equipment-control-contract`(capability `wms_wcs-equipment-control`,
아직 미구현)는 WMS가 자동화 설비를 등록·지시·모니터링하는 범용 소프트웨어
계약을 정의했다. 그 스펙의 D7은 `command_type`을 열린 집합으로 남기며 "고속
분류(Divert 슈트 번호, 가변 속도 값) 같은 도메인 특화 파라미터는 이번 스펙이
미리 정의하지 않는다 — 후속 스펙이 payload 안에 자신의 필드를 정의하거나,
필요하면 command_type 값 집합을 확장하는 마이그레이션만 추가하면 된다"고
명시했고, 확장 지점 표에서 이 변경(`wms_wcs-sortation-logic`)을 정확히
지목했다. `add-wes-material-flow-control`(capability
`wms_wes-material-flow-control`, 아직 미구현)도 같은 표에서 "`work_order.command_type`/
`command_payload`에 `DIVERT`, `SET_SPEED` 등을 채워 이 계약의 디스패치 경로를
그대로 사용한다. 새 테이블 불필요"라고 예견했다.

`docs/04-wms-wcs-market-feature-catalog.md` §2.3, §3의 Dematic iQ 세부 스펙이
정리한 실제 고속 분류기 동작(QNX RTOS 기반 고속 처리, Carton Gapping, Scanning,
Divert Control, Auto Speed Control)은 두 가지 축으로 나뉜다: (1) 설비가
지속적으로 유지하는 **튜닝 가능한 설정값**(최소 간격, 속도 범위, 센서 감지
윈도우) — 이는 명령이 아니라 설비별 마스터데이터에 가깝다. (2) 개별 아이템
단위로 실행되는 **명령**(어느 슈트로 보낼지, 속도를 얼마로 바꿀지) — 이는
`wms_wcs-equipment-control`의 명령 봉투 위에서 표현 가능하다. 이 설계는 (1)을
위한 새 테이블 하나와, (2)를 위한 `payload` 구조·검증 규칙만 추가한다 — 설비
등록, 명령 생애주기, 상태·장애 상태 기계는 전혀 새로 만들지 않는다.

### 정직한 전제 확인 (구현 상태)

> **구현 노트 (작성 이후 갱신)**: 아래 "아직 구현되지 않았다"는 전제는 이 문서
> 작성 시점 기준이며 더 이상 사실이 아니다. `20260727_wcs_equipment_control.sql`과
> `20260728_wes_material_flow_control.sql`이 모두 적용되어 있고, 이 변경도
> `20260729_wcs_sortation_logic.sql`로 구현되었다. 구현 과정에서 확인된 이
> 문서와 실제 코드의 차이 3건(D2/D3의 "디스패치 RPC는 수정하지 않는다"가 불가능한
> 이유, `WMS_ADMIN`의 디스패치 불가, 거부된 payload의 감사 기록 불가)은 tasks.md
> 0.2·3.5와 `openspec/specs/wms_wcs-sortation-logic/e2e/README.md`
> "Documented deviations"에 근거와 함께 기록했다. 역할 목록(아래 "역할 모델")은
> 실제 구현과 일치하므로 수정하지 않았다.

- **`wms_wcs-equipment-control`과 `wms_wes-material-flow-control` 모두 아직
  구현되지 않았다.** `supabase/migrations/`에 두 스펙의 마이그레이션 파일이
  없다. 이 설계가 참조하는 `wms.equipment`, `wms.equipment_commands`,
  `wms.equipment_status_events`, `wms_dispatch_equipment_command`,
  `wms_report_command_result`, `wms_raise_equipment_fault`는 모두 그 스펙들의
  design.md에 있는 **검토용 후보**이며, 실제 DB에는 존재하지 않는다. 이 변경의
  마이그레이션은 최소한 `wms_wcs-equipment-control`의 마이그레이션이 먼저
  적용된 뒤에만 적용할 수 있다(tasks.md 0장 참고).
- **이 저장소에는 handling unit(HU)/카톤 바코드 테이블이 없다.**
  `wms.stock_ledger_entries`는 `product_id`(SKU) 단위로만 재고를 추적하고,
  실물 낱개 카톤·팔레트를 스캔 식별자로 추적하는 테이블이 없다. 실제 벤더(Dematic
  iQ 등)의 Divert 제어는 카톤 단위 바코드 스캔을 전제하지만, 이 계약은 그
  모델을 새로 만들지 않는다 — 대신 Divert 명령의 아이템 식별자를 참조
  무결성이 없는 범용 텍스트 필드(`item_identifier`)로 설계한다(D6). HU
  모델링 자체는 이 변경의 범위가 아니다.
- **`wms.sortation_profiles`는 실물 프로파일이 아니라 소프트웨어 계약이다.**
  실제 분류기가 이 값을 준수하도록 강제하는 것은 PLC/필드버스 몫이며, 이
  계약은 그 값을 저장·조회·검증(요청 시 범위 확인)까지만 담당한다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블과 RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

## Goals / Non-Goals

**Goals:**

- `SORTER`/`CONVEYOR` 설비별로 최소 화물 간격, 속도 모드(고정/자동)와 범위,
  센서 감지 윈도우를 등록·조회·갱신하는 마스터데이터 계약.
- `wms_wcs-equipment-control`의 명령 봉투를 그대로 재사용해 Divert(슈트
  라우팅)와 속도 조정(고정값 지정 또는 자동 모드 위임) 명령의 `payload` 구조를
  정의하고, 디스패치 시점에 그 구조와 속도 범위를 검증.
- 분류 결과(성공/오분류/잼)를 `wms_wcs-equipment-control`의 "명령 결과 보고"
  계약이 이미 지원하는 `COMPLETED`/`FAILED` 상태와 `detail` 필드에 매핑하는
  규약.
- 잼(물리적 정체)이 보고되면 별도 수동 신고 없이 자동으로 설비 장애를
  발생시켜(D4·D5) `wms_wcs-equipment-control`의 기존 장애 처리 절차(진행 중
  명령 일괄 `FAILED`, 사람 확인 후 해소)로 자연스럽게 이어지게 함.
- 후속 세 영역(지능형 라우팅/병목 해소, 서열 출고/지능형 적재, 디지털
  트윈/시뮬레이션)이 새 설비·명령 개념을 다시 만들지 않고 이 위에 얹을 수
  있는 확장 지점.

**Non-Goals:**

- **병목 감지·경로 재설정 알고리즘.** 이 계약은 개별 Divert 명령의 성공/실패만
  다룬다 — 여러 설비에 걸친 흐름 재분배나 실시간 우회 판단은 후속 스펙
  `wms_wcs-intelligent-routing`(가칭, 지능형 라우팅/병목 해소)에서 다룬다.
- **서열 출고 순서 계산, 다중 로봇 셀 팔레타이징 최적화.** 카탈로그의 "로봇
  팔레타이징 셀: 중량/용적 센서 레벨 미세 제어"는 언급되어 있지만, 그 제어가
  요구하는 "적재 순서" 개념은 후속 스펙 `wms_wcs-sequential-dispatch`(가칭,
  서열 출고/지능형 적재)에서 다룬다. 이 계약의 속도 조정 payload는 `SORTER`/
  `CONVEYOR`에만 적용되며 `ROBOT_CELL`을 다루지 않는다.
- **디지털 트윈 시뮬레이션 엔진.** 후속 스펙에서 다룬다.
- **실제 PLC/필드버스 레벨의 간격·속도 강제 실행.** `wms.sortation_profiles`는
  값을 저장·검증할 뿐, 그 값을 실제 컨베이어 모터·센서에 적용하는 것은
  여전히 설비 쪽(실 WCS/PLC 게이트웨이 또는 시뮬레이터)의 책임이다.
- **부하 감응 자동 속도 제어의 실시간 판단 로직.** `speed_mode='AUTO'`는 이
  계약에서 "설비가 프로파일 범위 안에서 스스로 속도를 조절하도록 위임한다"는
  모드 전환 지시일 뿐이다 — 센서 신호를 읽고 실제 속도를 결정하는 로직은
  설비 내부(PLC) 또는 후속 디지털 트윈 스펙의 몫이다.
- **HU/카톤 바코드 모델 신설.** 이 저장소에 없는 handling unit 개념을 이
  변경에서 새로 만들지 않는다(위 "정직한 전제 확인" 참고).
- **동일 `equipment_type`에 대한 유형별 기본 프로파일(2단 상속) 구조.**
  이번 스펙은 설비별(1:1) 프로파일만 다룬다(D7).
- 프론트엔드 화면 구현.

## Decisions

### D1. 분류 프로파일은 명령이 아니라 별도 마스터데이터 테이블로 둔다

`wms.equipment_commands`에 `command_type='CONFIGURE_SORTATION'` 같은 명령을
추가해 `payload`에 설정값을 실어 보내는 대안도 검토했다. 그러나 프로파일은
명령처럼 "한 번 실행되고 종결되는" 생애주기가 아니라 "지속적으로 유지되며
다른 명령을 검증할 때 조회되는" 상태값이다 — 명령 이력에서 최신 `CONFIGURE_SORTATION`
레코드를 매번 역추적해야 한다면 `SET_SPEED` 디스패치마다 명령 로그 전체를
스캔해야 해서 검증 비용과 코드 복잡도가 커진다. 별도 테이블(`wms.sortation_profiles`,
`equipment_id` 유니크)로 두면 "설비의 현재 설정"이 항상 단일 행 조회로
끝난다.

### D2. `command_type` 확장은 새 마이그레이션에서 `CHECK` 제약을 교체하는
방식으로 하고, 선행 변경이 소유한 원본 마이그레이션 파일은 수정하지 않는다

`wms_wcs-equipment-control`의 D7이 정확히 이 경로를 예견했다: "필요하면
`command_type` 값 집합을 확장하는 마이그레이션만 추가하면 된다. 테이블 구조
자체는 바뀌지 않는다." 이 변경은 그 경로를 그대로 따른다 — 이 변경의
마이그레이션 파일에서 `alter table wms.equipment_commands drop constraint
<기존 제약명>, add constraint ... check (command_type in (..., 'DIVERT',
'SET_SPEED'))`를 실행한다. `add-wes-material-flow-control`이 이미 같은 종류의
교차 스펙 의존성(D2, `wms.equipment_commands`에 트리거 추가)을 선례로 남겼다
— 이 변경은 같은 원칙(원 테이블 정의는 손대지 않고, 그 위에 얹는 후속
마이그레이션만 추가)을 제약 조건에도 적용한다.

### D3. Divert/속도 조정 payload 검증은 새 RPC가 아니라 `wms.equipment_commands`의
`BEFORE INSERT` 트리거로 구현한다

`wms_dispatch_equipment_command` 자체를 수정하거나 감싸는 새 RPC를 만드는
대안도 검토했다. 그러나 `wms_wcs-equipment-control`은 이미 그 RPC를 "낙관적
동시성 검증 후 `PENDING` 명령 생성"이라는 범용 계약으로 확정해 뒀고, 이
변경이 그 RPC를 다시 정의하면 두 스펙이 같은 RPC를 서로 다르게 문서화하는
drift 위험이 생긴다. 대신 `add-wes-material-flow-control`의 D2(완료 전파
트리거)와 같은 패턴 — 선행 변경이 소유한 테이블에 이 변경의 마이그레이션에서
트리거만 얹는다 — 을 검증에도 적용한다. 트리거는 다음을 검사한다:

- `NEW.command_type in ('DIVERT', 'SET_SPEED')`이면 대상 설비의
  `equipment_type`이 `SORTER` 또는 `CONVEYOR`인지 확인 — 아니면 `INVALID:`.
- `DIVERT`면 `payload`에 `target_chute`, `item_identifier`가 모두 존재하는지
  확인 — 아니면 `INVALID:`.
- `SET_SPEED`면 `payload.speed_mode`가 `FIXED`/`AUTO` 중 하나인지 확인하고,
  `FIXED`면 `payload.speed_value`가 그 설비의 `wms.sortation_profiles`에 등록된
  `min_speed_value`~`max_speed_value` 범위 안인지, `payload.speed_unit`이
  프로파일의 `speed_unit`과 일치하는지 확인 — 하나라도 어긋나면 `INVALID:`.
- 대상 설비에 `wms.sortation_profiles` 레코드 자체가 없으면 `DIVERT`/`SET_SPEED`
  모두 거부한다 — 프로파일 없이는 간격·속도 기준이 없어 검증이 불가능하기
  때문이다(운영 절차상 "설비 등록 → 프로파일 등록 → 분류 명령 디스패치"
  순서를 강제).

트리거는 `INVALID: ...` 접두 예외를 그대로 발생시켜 이 저장소의 기존
오류 규약과 일치시킨다.

### D4. 분류 결과 outcome은 명령 결과 보고의 `detail` 필드로 표현하고, 명령
상태와의 정합성을 검증한다

새 상태값을 추가하지 않는다 — `wms_wcs-equipment-control`의 "명령 결과 보고"
Requirement가 이미 `COMPLETED`/`FAILED`를 지원한다. 이 계약은 `DIVERT` 명령의
`wms_report_command_result` 호출에서 `p_detail.outcome`이 `SUCCESS`,
`MISROUTE`, `JAM` 중 하나이길 기대하고, 그 값과 `p_command_status`의 정합성을
`wms.equipment_status_events`의 `BEFORE INSERT` 트리거로 검증한다: `outcome='SUCCESS'`는
`command_status='COMPLETED'`만 허용하고, `outcome`이 `MISROUTE`/`JAM`이면
`command_status='FAILED'`만 허용한다 — 어긋나면 `INVALID:`. 대안으로 "outcome을
아예 강제하지 않고 자유 텍스트로 둔다"도 고려했으나, 그러면 후속 영역이나
모니터링 화면이 "성공/오분류/잼"을 구분하려 할 때마다 `detail`의 자유
텍스트를 파싱해야 해서 일관성이 없어진다.

### D5. 잼(JAM)만 자동으로 설비 장애를 승격하고, 오분류(MISROUTE)는 승격하지
않는다

카탈로그가 시사하는 "비상 장애 시나리오 기반 실시간 복구" 패턴을 물리적
정체(잼)에는 적용하되, 오분류에는 적용하지 않는다 — 오분류는 대개 스캔·라우팅
로직의 개별 실패이고 설비 자체가 멈추지 않지만, 잼은 설비가 물리적으로
막혀 후속 명령도 처리할 수 없는 상태이기 때문이다. `wms.equipment_status_events`에
`AFTER INSERT` 트리거를 추가해 `NEW.event_type='COMMAND_FAILED'`이고
`NEW.detail->>'outcome'='JAM'`이면, 그 명령의 설비에 대해
`wms_raise_equipment_fault`와 동일한 로직(장애 레코드 생성, 설비 상태를
`FAULT`로 전환, 그 설비의 미종결 명령 일괄 `FAILED` 전환 — `wms_wcs-equipment-control`
D4)을 내부적으로 재사용한다. 새 SQL을 중복 작성하지 않기 위해, 트리거는
가능하면 `wms_raise_equipment_fault` 함수 자체를 직접 호출한다(둘 다
`SECURITY DEFINER`이므로 함수 간 호출이 가능하다) — `fault_code='SORTATION_JAM'`,
`severity='CRITICAL'`, `raised_by`는 원 보고자(`WCS_GATEWAY`)로 채운다.

### D6. Divert 아이템 식별자는 handling unit이 아니라 범용 텍스트로 둔다

이 저장소에는 카톤/팔레트 단위 스캔 식별자를 담는 테이블이 없다(위 "정직한
전제 확인"). `DIVERT` payload의 `item_identifier`를 `wms.products`나
`wms.stock_ledger_entries`를 가리키는 외래키로 만드는 대안도 검토했으나,
실제 분류기가 스캔하는 것은 SKU가 아니라 개별 카톤의 바코드이므로 SKU
외래키로는 "같은 SKU의 카톤 100개 중 몇 번째가 오분류됐는가"를 표현할 수
없다. 대신 `item_identifier`를 참조 무결성이 없는 자유 텍스트로 두고, WMS
쪽 업무와의 성긴 연결이 필요하면 명령 자체의 `linked_entity_type`/
`linked_entity_id`(예: `'receipt'`, `wms_wcs-equipment-control`의 D6)를 그대로
쓰게 한다. HU 모델을 도입하는 것은 이 변경보다 훨씬 넓은 스코프(입고·적치·출고
전체에 영향)이므로 범위 밖에 남긴다.

### D7. 프로파일은 설비 단위(1:1)로만 두고, 유형별 기본값 상속은 다루지 않는다

"`equipment_type`별 기본 프로파일 + 설비별 override"라는 2단 구조도 고려했다.
그러나 이 샘플 앱은 창고당 동일 유형 설비가 다수 존재하는 대규모 데모가
아니고, 설비별 프로파일만으로 이번 스펙의 모든 시나리오(간격·속도 검증)를
충분히 표현할 수 있다. 기본값 상속은 실제 대규모 배포에서나 의미가 커지는
최적화이므로, 필요해지면 `wms.sortation_profiles`에 `equipment_type` 단독
행(`equipment_id is null`)을 허용하는 후속 마이그레이션으로 추가할 수 있게
설계만 열어 둔다(이번 변경은 `equipment_id not null`로 시작).

### D8. `speed_mode='AUTO'`는 모드 전환 지시일 뿐, 실시간 속도 결정 로직을
포함하지 않는다

카탈로그의 "Auto Speed Control"을 이 계약이 직접 구현하면 부하 센서 신호
수집·실시간 제어 루프가 필요해져 `wms_wcs-equipment-control`이 이미 그은
"실제 PLC/필드버스 제어는 범위 밖" 경계를 넘는다. 이 계약은 `SET_SPEED`
명령의 `speed_mode='AUTO'`를 "설비가 프로파일의 `min_speed_value`~
`max_speed_value` 범위 안에서 스스로 속도를 조절하도록 위임하라"는 소프트웨어
지시로만 정의한다 — 그 지시를 받은 뒤 실제로 어떻게 속도를 조절하는지는
설비(또는 그 설비 역할을 하는 시뮬레이터/디지털 트윈)의 몫이다.

## 데이터 모델 (검토용 후보)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은 구현 단계에서
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`과 `wms_wcs-equipment-control`의 마이그레이션은
> 수정하지 않으며, 그 마이그레이션이 먼저 적용된 뒤에만 이 변경의 마이그레이션을
> 적용할 수 있다.

### `wms.sortation_profiles` — 분류 설비 프로파일 (신규 테이블)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `equipment_id` | `uuid` | FK `wms.equipment`, unique(D7) — `equipment_type`이 `SORTER`/`CONVEYOR`인 설비만 허용(RPC에서 검증, DB `CHECK`로는 교차 테이블 제약 불가) |
| `min_carton_gap_mm` | `int` | 카톤 간 최소 간격(mm), `> 0` |
| `speed_mode` | `text` | `FIXED \| AUTO`, 기본값 `FIXED` — 프로파일의 기본 모드(개별 `SET_SPEED` 명령이 이를 재지정할 수 있음) |
| `min_speed_value` / `max_speed_value` | `numeric` | 속도 허용 범위, `min_speed_value <= max_speed_value` |
| `speed_unit` | `text` | 예: `MPS`(초당 미터) — 자유 텍스트지만 같은 설비의 모든 `SET_SPEED` payload와 일치해야 함(D3) |
| `sensor_detection_window_ms` | `int` | 스캔/감지 윈도우(ms), `> 0` |
| `status` | `text` | `ACTIVE \| INACTIVE` — `INACTIVE`면 D3 트리거가 검증을 건너뛰지 않고 오히려 `DIVERT`/`SET_SPEED`를 거부한다(프로파일이 비활성화된 설비는 튜닝 기준이 없는 것과 동일하게 취급) |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.equipment_commands.command_type` — `CHECK` 제약 확장 (D2)

```sql
alter table wms.equipment_commands
  drop constraint equipment_commands_command_type_check; -- 선행 변경이 실제로 붙인 제약명으로 교체
alter table wms.equipment_commands
  add constraint equipment_commands_command_type_check
  check (command_type in (
    'MOVE','LOAD','UNLOAD','START','STOP','RESET','HOLD','RESUME',
    'DIVERT','SET_SPEED'
  ));
```

### `DIVERT` 명령 `payload` 구조 (계약, 새 컬럼 아님)

```json
{
  "target_chute": "CHUTE-12",
  "item_identifier": "carton-barcode-or-freeform-id",
  "expected_gap_mm": 150
}
```

- `target_chute`(text, 필수): 목적 슈트/Divert 위치 식별자.
- `item_identifier`(text, 필수): 라우팅 대상 아이템의 스캔 식별자. 참조
  무결성 없는 자유 텍스트(D6).
- `expected_gap_mm`(int, 선택): 명시하지 않으면 그 설비 프로파일의
  `min_carton_gap_mm`을 기대값으로 간주한다.

### `SET_SPEED` 명령 `payload` 구조 (계약, 새 컬럼 아님)

```json
{
  "speed_mode": "FIXED",
  "speed_value": 1.8,
  "speed_unit": "MPS"
}
```

- `speed_mode`(text, 필수): `FIXED \| AUTO`.
- `speed_value`(numeric, `speed_mode='FIXED'`일 때 필수): 프로파일
  `min_speed_value`~`max_speed_value` 범위 안이어야 한다(D3). `speed_mode='AUTO'`면
  무시되거나 생략 가능(D8).
- `speed_unit`(text, 필수): 프로파일의 `speed_unit`과 일치해야 한다.

### `wms_report_command_result`의 `p_detail` 구조 — `DIVERT` 결과 (계약, 새 컬럼 아님)

```json
{
  "outcome": "SUCCESS",
  "actual_chute": "CHUTE-12",
  "reason": "선택: MISROUTE/JAM일 때 사유"
}
```

- `outcome`(text, 필수): `SUCCESS \| MISROUTE \| JAM`(D4). `p_command_status`와의
  매핑은 아래 표.
- `actual_chute`(text, 선택): 실제로 라우팅된 슈트 — `MISROUTE`일 때
  `target_chute`와 달라야 의미가 있다.

| `outcome` | 허용되는 `p_command_status` | 부가 효과 |
|---|---|---|
| `SUCCESS` | `COMPLETED`만 | 없음 |
| `MISROUTE` | `FAILED`만 | 없음(자동 장애 승격 안 함, D5) |
| `JAM` | `FAILED`만 | 자동으로 설비 장애 발생(D5) — `fault_code='SORTATION_JAM'`, `severity='CRITICAL'` |

## RPC 계약 (검토용 시그니처 초안)

모든 RPC는 기존과 동일하게 `language plpgsql security definer set search_path =
wms, public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only)를 따른다. `DIVERT`/`SET_SPEED`
명령 디스패치·결과 보고는 새 RPC를 만들지 않고 `wms_wcs-equipment-control`의
`wms_dispatch_equipment_command`/`wms_report_command_result`/
`wms_cancel_equipment_command`를 그대로 사용한다(payload로 구분).

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_create_sortation_profile` | `p_equipment_id, p_min_carton_gap_mm, p_speed_mode default 'FIXED', p_min_speed_value, p_max_speed_value, p_speed_unit default 'MPS', p_sensor_detection_window_ms, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` | 대상 설비의 `equipment_type`이 `SORTER`/`CONVEYOR`가 아니면 `INVALID:`. 이미 프로파일이 있으면 `INVALID:`(갱신은 별도 RPC) |
| `wms_update_sortation_profile` | `p_profile_id, p_min_carton_gap_mm, p_speed_mode, p_min_speed_value, p_max_speed_value, p_speed_unit, p_sensor_detection_window_ms, p_status, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` | `expected_version`은 프로파일 버전 |
| `wms_get_sortation_profile` | `p_tenant_id, p_warehouse_id, p_equipment_id default null` | 모든 테넌트/창고 멤버(읽기) | 설비 + 프로파일을 조인한 조회 전용 함수 |

모든 쓰기 RPC는 성공 시 `{result: 'ok', document_id, status, version,
next_actions, warnings?}` 형태를 반환하고, `wms.audit_events`에
`entity_type='sortation_profile'` 레코드를 남긴다. `DIVERT`/`SET_SPEED` 명령
디스패치가 이 계약의 트리거(D3)에 의해 거부되면, 호출자에게는 여전히
`wms_dispatch_equipment_command`가 반환하는 `INVALID:` 오류로 보인다 — 별도
오류 채널을 만들지 않는다.

## 역할 모델

새 역할을 추가하지 않는다. 기존 역할 재사용:

| 역할 | 이 계약에서의 권한 |
|---|---|
| `WMS_ADMIN` | 프로파일 등록·갱신·조회 |
| `WAREHOUSE_MANAGER` | 프로파일 등록·갱신·조회 |
| `WCS_OPERATOR` | 프로파일 등록·갱신·조회 (설비 튜닝은 운영자 몫) |
| `PROCESS_AGENT` | 프로파일 관리 권한 없음(읽기 전용 조회만) — Divert/속도 조정 명령
  디스패치는 `wms_wcs-equipment-control`의 기존 `wms_dispatch_equipment_command`
  허용 역할을 그대로 따른다(이 계약이 별도로 제한하지 않음) |
| `WCS_GATEWAY` | 분류 결과 보고는 `wms_wcs-equipment-control`의
  `wms_report_command_result` 허용 역할을 그대로 따름. 프로파일 관리 권한 없음 |

## RLS 패턴

기존 테이블과 동일하게, 신규 테이블 `wms.sortation_profiles`:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer` RPC를
  통해서만 이루어진다.

`wms.equipment_commands`, `wms.equipment_status_events`의 기존 RLS 정책은
변경하지 않는다 — 이 계약이 추가하는 트리거는 정책이 아니라 트리거 함수
안에서 동작하므로 RLS와 독립적이다.

## 확장 지점 (후속 세 영역)

| 후속 영역 (가칭 spec ID) | 이 계약을 어떻게 확장하는가 |
|---|---|
| `wms_wcs-intelligent-routing`(지능형 라우팅/병목 해소) | `MISROUTE`/`JAM` 빈도를 관찰해 특정 슈트·설비를 회피하는 재라우팅 판단에 이 계약의 `detail.outcome` 값을 입력으로 쓴다. 이 계약을 수정할 필요 없음. |
| `wms_wcs-sequential-dispatch`(서열 출고/지능형 적재) | `ROBOT_CELL` 대상 적재 순서 제어는 이 계약의 범위 밖(Non-Goals)이지만, `wms.sortation_profiles`와 같은 "설비별 튜닝 마스터데이터" 패턴을 `ROBOT_CELL`에도 재사용할 수 있다(새 테이블 또는 이 테이블의 `equipment_type` 값 확장 후보). |
| `wms_wes-digital-twin`(디지털 트윈/시뮬레이션) | `WCS_GATEWAY`로 인증하는 시뮬레이터가 `wms_report_command_result`를 `outcome=SUCCESS/MISROUTE/JAM`로 호출하면, 이 계약의 검증·자동 장애 승격 트리거가 그대로 반응한다 — 이 계약을 수정할 필요 없음. |

## 프론트엔드 확장 지점 (구현 아님, 위치만 기록)

> **구현 노트**: 구현 단계에서 범위를 넓혀 이 절이 "후속"으로 미뤄 둔 화면까지
> 함께 만들었다 — `frontend/src/views/WcsSortationView.vue`, 라우트
> `/wcs/sortation`(프로파일 관리와 명령 전송을 함께 다루므로 아래 후보명보다
> 넓은 이름을 썼다). 자세한 내용은 tasks.md 7장.

- `/wcs/sortation-profiles` — 설비별 프로파일 등록·조회·수정 화면 후보.
  `frontend/src/views/`에 `SortationProfileView.vue` 형태로 추가될 후보.
- `/wcs/monitor`(선행 변경의 확장 지점) — 분류 결과(성공/오분류/잼) 비율을
  함께 보여주는 위젯을 추가할 여지가 있으나, 이번 변경은 그 화면을
  구현하지 않는다.

## Risks / Trade-offs

- **두 선행 변경(둘 다 미구현) 위에 쌓인 스펙이다.** 완화책: 이 변경의 E2E는
  선행 변경들이 준비한 시뮬레이터 스크립트를 재사용해 왕복 검증하고,
  tasks.md에 마이그레이션 적용 순서를 명시한다.
- **`command_type` `CHECK` 제약을 다른 변경이 소유한 테이블에서 교체하는
  것(D2)은 제약명이 선행 변경의 실제 구현과 다르면 마이그레이션이 실패할
  위험이 있다.** 완화책: tasks.md에 "선행 변경 마이그레이션 적용 후 실제
  제약명을 `information_schema`로 확인한 뒤 이 변경의 마이그레이션에 반영"
  단계를 명시한다.
- **`BEFORE INSERT`/`AFTER INSERT` 트리거 두 개가 선행 변경의 두 테이블에
  얹힌다(D3, D5).** 완화책: 트리거 정의를 이 변경의 마이그레이션 파일에만
  두고, 원 테이블 정의 자체는 건드리지 않는다 — 선행 변경이 나중에 그
  테이블 구조를 바꾸면 이 트리거도 함께 재검토해야 함을 tasks.md에 남긴다.
- **`item_identifier`를 참조 무결성 없는 텍스트로 둔 것(D6)은 오분류 추적의
  정확도를 제한한다.** 완화책: 이 저장소에 HU 모델이 생기면 그때
  `item_identifier`를 대체하거나 병행하는 후속 마이그레이션을 고려한다 —
  지금은 그 모델 자체가 없으므로 선제적으로 만들지 않는다.
- **`speed_mode='AUTO'`가 "위임 지시"에 그치는 것(D8)은 실제 부하 감응 제어의
  검증 가능성을 낮춘다.** 완화책: E2E는 `AUTO` 모드 전환 지시가 올바르게
  기록·조회되는지까지만 검증하고, 실제 속도 변화 검증은 시뮬레이터가
  `wms_report_command_result`로 결과를 보고하는 수준까지만 다룬다(하드웨어
  루프 자체는 검증 대상이 아님을 tasks.md에 명시).
