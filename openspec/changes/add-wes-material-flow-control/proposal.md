## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.2 "WES/MFS", §3, 벤더별 세부 스펙)가
보여주듯, 실제 WMS/WCS 시장의 WES(Warehouse Execution System)/MFS(Material Flow
System) 계층은 예외 없이 두 가지 일을 한다 — (1) 웨이브(Wave)/Waveless(On-Demand)/
하이브리드 같은 "동적 작업 이행 전략"으로 언제 작업을 실행할지 결정하고, (2) WMS
상위 지시와 WCS 설비 하부 동작 사이의 미들웨어로서 설비 간 흐름을 균형 있게
배분한다. SAP EWM은 이를 "내장 MFS 모듈을 통한 PLC/WCS 직접 데이터 연동"으로,
Dematic iQ Optimize는 "Wave/Waveless/Hybrid 이행 전략"으로, Swisslog SynQ는
"단일 통합 데이터베이스 기반 설비-소프트웨어 제어"로 구현한다.

이 저장소는 직전 변경(`add-wcs-equipment-control-contract`, capability
`wms_wcs-equipment-control`)에서 설비 레지스트리·명령 디스패치·상태 피드백·장애
처리라는 **WMS↔설비 소프트웨어 계약**을 정의했다. 그 스펙은 `wms.equipment_commands`가
WMS 쪽 작업을 가리키는 `linked_entity_type`/`linked_entity_id`를 가질 수 있다고
정의했지만, "누가 그 컬럼을 채우는가", "설비 명령 결과가 보고되면 WMS 쪽 작업
상태를 누가, 어떻게 되돌리는가"는 의도적으로 열어 뒀다 — 해당 스펙의 "명령 결과
보고" Requirement는 "연결된 WMS 엔티티 자체의 상태를 이 계약이 직접 변경하지는
않는다(각 소비 스펙이 이 이벤트를 구독해 자신의 상태 전이를 결정한다)"고 명시한다.

이 변경은 바로 그 **소비 스펙**이다 — WMS 상위 작업 의도(현재는 `wms.receipts`가
적치가 필요한 상태에 도달한 것이 유일한 실제 후보)를 하나 이상의 설비 명령으로
번역해 디스패치하고, 설비 쪽 명령 결과를 구독해 WMS 상위 작업의 상태로 되돌리는
미들웨어 계층을 정의한다.

**정직한 전제 확인**: `add-wcs-equipment-control-contract`는 아직 구현되지
않았다 — `supabase/migrations/`에 해당 마이그레이션 파일이 없고, `wms.equipment`,
`wms.equipment_commands` 등은 현재 실행 중인 데이터베이스에 존재하지 않는다. 이
변경은 그 스펙(설계 문서)을 근거로 삼아 그 위에 이어 쓰는 스펙이며, 두 변경 모두
구현 단계에서는 `add-wcs-equipment-control-contract`의 마이그레이션이 먼저
적용된 뒤에만 이 변경의 마이그레이션을 적용할 수 있다. 또한 이 저장소의 실제
스키마에는 `wms.warehouse_tasks`가 없다 — `wms_create_putaway_tasks`는
`wms.receipts` 상태 전이와 원장 반영을 한 호출로 축약한 데모 슬라이스이며, 이
변경도 그 전제를 그대로 따른다(가상의 `warehouse_tasks`나, 아직 이 저장소에 없는
`wms_release_wave`/출고 웨이브 개념을 존재하는 것처럼 다루지 않는다).

## What Changes

- `wms` 스키마(기존과 동일 schema/인스턴스, 동일 RLS/RPC 봉투 규약)에 WES/MFS
  업무 오더(work order)와 디스패치 웨이브를 위한 새 테이블을 추가한다. 신규
  서비스나 신규 데이터베이스를 만들지 않는다.
- 기존 RPC와 동일한 봉투(`tenant_id, warehouse_id, actor_id, idempotency_key,
  expected_version, correlation_id` 입력 / `{result, document_id, status,
  version, next_actions, warnings}` 출력, `CONFLICT:`/`FORBIDDEN:`/`INVALID:`
  접두 예외)를 따르는 새 RPC 세트를 추가한다: 디스패치 웨이브 개설, 업무 오더
  등록(Wave/Waveless 중 선택), 웨이브 릴리즈, 업무 오더 재디스패치 시도, 업무
  오더 취소, 업무 오더/웨이브 조회.
- 업무 오더를 디스패치할 때 `wms_wcs-equipment-control`의
  `wms_dispatch_equipment_command`를 호출해 적합한 가용 설비(같은 `equipment_type`,
  같은 `zone_code`, `status='IDLE'`, 미종결 명령 없음)를 선택하는 간단한 흐름
  균형(부하 분산) 로직을 추가한다 — 병목 예측이나 최적화 알고리즘은 다루지
  않는다.
- 설비 명령이 `COMPLETED`/`FAILED`로 보고되면 그 명령에 연결된 업무 오더의
  상태를 자동으로 갱신하는 완료 전파 메커니즘을 추가한다 — 이는
  `wms_wcs-equipment-control`의 "명령 결과 보고" Requirement가 열어 둔 구독
  지점을 채우는 것이다. 다만 업무 오더가 참조하는 WMS 상위 엔티티(예:
  `wms.receipts`) 자체의 상태를 이 변경이 직접 되돌리지는 않는다 — 그건 이
  변경을 다시 소비하는 오케스트레이션(ProcessGPT 또는 후속 통합)의 책임이다.
- `mcp/wms_mcp/mcp_server.py`에 위 RPC를 감싸는 새 `@mcp.tool` 함수들을
  추가한다(기존 도구와 같은 패턴).
- 새 service role은 추가하지 않는다 — 이 계층은 설비가 아니라 WMS 내부
  오케스트레이션(사람 운영자 또는 `PROCESS_AGENT`)이 호출하므로, 기존
  `WAREHOUSE_MANAGER`/`WCS_OPERATOR`/`PROCESS_AGENT`/`WMS_ADMIN` 역할을 그대로
  재사용한다.
- 고속 분류 제어, 지능형 라우팅/병목 해소, 서열 출고/지능형 적재, 디지털
  트윈/시뮬레이션 로직은 이번 변경에 포함하지 않는다 — 이 미들웨어 위에
  얹을 확장 지점만 남긴다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "WES/MFS 자재 흐름 제어"
  행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_wes-material-flow-control`: WMS 상위 작업 의도를 업무 오더로 등록하고,
  Wave(배치 큐잉·릴리즈) 또는 Waveless(즉시 디스패치) 전략에 따라 적합한 가용
  설비를 선택해 `wms_wcs-equipment-control`의 명령 디스패치 계약으로 번역하며,
  설비 명령 결과를 업무 오더 상태로 되돌리는 WMS-WCS 미들웨어 계약.

### Modified Capabilities

(없음 — 기존 스펙의 요구사항을 변경하지 않는다. `wms_wcs-equipment-control`이
열어 둔 구독 지점을 채울 뿐, 그 스펙 자체의 Requirement는 그대로 둔다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 2종(`wms.dispatch_waves`,
  `wms.work_orders`)과 신규 RPC 6종, 신규 RLS 정책 추가. `wms_wcs-equipment-control`의
  `wms.equipment_commands` 테이블에 완료 전파용 트리거를 추가한다(그 테이블은
  이 변경이 아니라 선행 변경이 소유 — 배포 순서 의존성이 생긴다, design.md
  참고). 기존 `20260726_wms_core_schema.sql`의 테이블/RPC는 변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 6종 추가. 기존 도구는
  변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/wes/work-orders`(업무 오더 현황), `/wes/waves`(웨이브 계획·릴리즈) 라우트가
  추후 이 계약 위에 얹힐 수 있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: 변경 없음(기존 4개 역할 재사용).
- **선행 의존성**: 이 변경은 `add-wcs-equipment-control-contract`(capability
  `wms_wcs-equipment-control`)가 정의하는 테이블/RPC를 전제로 한다. 그 변경이
  아직 구현되지 않았으므로, 이 변경의 마이그레이션도 실제 DB에는 그 변경의
  마이그레이션이 먼저 적용된 뒤에만 적용할 수 있다.
- **후속 영역**: 고속 분류 제어, 지능형 라우팅/병목 해소, 서열 출고/지능형
  적재, 디지털 트윈/시뮬레이션은 이 계약과 `wms_wcs-equipment-control`을 함께
  소비하는 별도 변경으로 이후 진행한다(이번 변경에 포함하지 않음).
