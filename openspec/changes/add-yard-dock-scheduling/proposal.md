## Why

`docs/04-wms-wcs-market-feature-catalog.md`(§2.1 "야드 및 도크 관리", SAP EWM
절의 "Dock Appointment Scheduling")가 보여주듯, 실제 WMS 제품은 예외 없이
"입출고 차량 스케줄링(Dock Appointment Scheduling)"과 "야드 내 차량/화물 위치
추적"을 다룬다. 그러나 이 샘플 앱의 `wms` 스키마에는 도크라는 개념이 전혀
없다 — `wms.receipts`는 `wms_register_arrival` RPC로 `EXPECTED -> ARRIVED`
전이만 수행할 뿐, 어느 도크에서, 어느 시간창에 하역이 이루어지는지에 대한
계약이 없다.

동시에 main repo `openspec/changes/supabase-wms-erp-replacement/design.md`
§7.2 "창고 기준정보"는 원래 목표 모델에 `warehouses, zones, locations, docks`를
위치 모델 엔티티로 나열했지만, 이 저장소가 실제로 구현한 스키마
(`supabase/migrations/20260726_wms_core_schema.sql`)는 `wms.warehouses`만
만들고 zones/locations/docks는 끝내 만들지 않았다. 이 변경은 그 중 도크
부분의 격차를 메운다.

이 영역은 area1~6(WCS/WES 체인)과 독립적이다 — 설비(equipment)나 명령
(command) 개념을 전혀 참조하지 않고, 순수하게 WMS 쪽 마스터데이터/입고 도메인을
확장한다.

## What Changes

- `wms` 스키마(기존과 동일 schema, 동일 RLS/RPC 봉투 관례)에 도크 레지스트리
  (`wms.docks`)와 도크 예약(`wms.dock_appointments`)을 위한 신규 테이블을
  추가한다. 신규 서비스나 신규 데이터베이스를 만들지 않는다.
- `wms.dock_appointments`에 Postgres `EXCLUDE USING gist` 제약을 적용해, 같은
  도크에 대해 진행 중(취소/출차 전) 예약의 시간창이 겹치면 DB 레벨에서 즉시
  거부되도록 한다(이중 예약 방지 — 애플리케이션 레벨 체크가 아니라 스토리지
  엔진 수준의 원자적 보장).
- 기존 명령 RPC와 동일한 봉투(`tenant_id, warehouse_id, actor_id,
  idempotency_key, expected_version, correlation_id` 입력 / `{result,
  document_id, status, version, ...}` 출력, `CONFLICT:`/`FORBIDDEN:`/`INVALID:`
  접두 예외)를 따르는 새 RPC 세트를 추가한다: 도크 등록, 도크 상태 전환(정비/
  재개방), 도크 예약 생성, 도크 예약 취소, 차량 야드 체크인, 차량 도킹(도크
  점유 시작), 차량 출차(도크 점유 해제), 도크 스케줄 조회.
- `mcp/wms_mcp/mcp_server.py`에 위 RPC를 감싸는 새 `@mcp.tool` 함수들을
  추가한다(기존 도구와 같은 패턴).
- 기존 `wms_register_arrival` RPC는 시그니처와 동작을 변경하지 않는다 — 이
  계약은 그 RPC와 독립적으로 동작하며, 도크 예약이 없어도 기존 입하 접수
  흐름은 그대로 성립한다(design.md D2 참고).
- 실시간 GPS/RTLS 기반 야드 내 연속 위치 추적은 다루지 않는다 — 체크인/도킹/
  출차라는 이산 상태 전이만 다룬다.
- `docs/04-wms-wcs-market-feature-catalog.md` §5 표에서 "야드 및 도크 관리"
  행을 스펙 완료로 갱신한다.

## Capabilities

### New Capabilities

- `wms_yard-dock-scheduling`: 창고별 도크 레지스트리 관리, PO(입고)에 연결된
  도크 예약(시간창+특정 도크) 생성·취소, 동일 도크의 겹치는 예약을 DB 레벨에서
  차단하는 이중 예약 방지, 차량의 야드 체크인·도킹·출차라는 이산 상태 전이,
  도크 스케줄 조회, 테넌트/창고 RLS 스코핑과 감사 추적을 포함하는 WMS 야드/도크
  관리 계약.

### Modified Capabilities

(없음 — 기존 스펙의 요구사항을 변경하지 않는다. `wms_register_arrival`을 포함한
기존 RPC는 시그니처·동작이 그대로 유지된다.)

## Impact

- **DB**: `wms` 스키마에 신규 테이블 2종(`wms.docks`, `wms.dock_appointments`),
  신규 exclusion 제약 1종(`btree_gist` extension 필요), 신규 RPC 8종, 신규 RLS
  정책 추가. 기존 테이블/RPC는 변경하지 않는다.
- **MCP**: `mcp/wms_mcp/mcp_server.py`에 신규 도구 7~8종 추가(읽기 전용 스케줄
  조회 포함). 기존 도구는 변경하지 않는다.
- **프론트엔드**: 이번 변경에는 화면 구현이 포함되지 않는다. `frontend/`에
  `/inbound/dock-schedule`(도크 스케줄 관리) 라우트가 추후 이 계약 위에
  얹힐 수 있음을 design.md에 확장 지점으로만 기록한다.
- **역할 모델**: 새 역할을 추가하지 않는다 — 기존 `WMS_ADMIN`,
  `WAREHOUSE_MANAGER`(area1 `wms_wcs-equipment-control`에서 이미 도입),
  `INBOUND_OPERATOR`, `PROCESS_AGENT` 역할을 재사용한다(design.md D5).
- **다른 영역과의 관계**: area1~6(WCS/WES 체인)과 독립적이다 — 이 계약은
  `wms.equipment`, `wms.equipment_commands` 등 어떤 설비/명령 개념도 참조하지
  않는다. main repo `wms_master-data`가 원래 구상했던 위치 모델의 `docks` 부분
  격차를 메운다.
