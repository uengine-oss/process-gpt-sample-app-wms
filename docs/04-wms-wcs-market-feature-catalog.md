# 국내외 WMS·WCS·WES 솔루션 기능 카탈로그

> 출처: `docs/WMS WCS 솔루션 및 매뉴얼.pdf`(국내외 솔루션 동향 종합 연구 보고서),
> `docs/각 제품들의 모든 기능들을 취합하여 주요기능리스트와 세부적인 기능 스펙 문서를 생성해보자.pdf`
> (통합 주요 기능 리스트 + 제품별 세부 기능 스펙). 조사 대상: 두산로지스틱스솔루션,
> 현대무벡스, LG CNS/SFA(국내) · SAP S/4HANA EWM, Manhattan Active WM,
> Dematic iQ, Swisslog SynQ(해외).
>
> 이 문서는 openspec 스펙을 쓰기 위한 **근거 카탈로그**다. 실제 스펙(`openspec/specs/wms_*`)은
> 이 카탈로그의 항목을 그대로 베끼지 않고, 이 샘플 앱의 실제 스코프(그린필드 데모, 사용자가
> 지정하는 영역)에 맞게 재해석해서 작성한다. §5에 이미 커버된 영역과 미착수 영역을 표시했다.

## 1. 영역 구분

시장 조사 결과 기능은 4개 상위 영역으로 나뉜다.

- **WMS** — 재고·주문·인력의 업무 관리
- **WES/MFS** — WMS의 지시와 WCS의 설비 동작 사이를 잇는 실행/자재흐름 계층
- **WCS** — 자동화 설비(SRM, 컨베이어, 분류기, AGV/AMR, 로봇) 직접 제어
- **차세대 플랫폼/AI** — 에이전틱 AI, 클라우드 네이티브, 감사·확장성

## 2. 통합 주요 기능 리스트 (영역별)

### 2.1 WMS

| 기능 그룹 | 세부 기능 |
|---|---|
| 마스터 데이터 관리 | 자재/SKU 속성 관리, 보관 위치(Bin) 정의, 카톤/팔레트 입수량·중량·용적을 포함한 포장 규격(Packaging Specification) 관리 |
| 입고 및 적치 | 구매 주문(PO) 연동, 핸들링 유닛(HU) 바코드 발행/스캔, 빈 공간 우선·고정 빈 등 적치 전략에 따른 최적 Bin 자동 추천, 창고 작업(WT) 생성 및 확정 |
| 재고 관리 및 최적화 | 실시간 Bin-to-Bin 재고 이동, SKU 출하 빈도 기반 슬롯팅(Slotting) 최적화, 피킹 빈 재고 부족 시 보충(Replenishment) 로직, 실시간 재고 가시성 |
| 출고 및 피킹 | 주문 수집·검증, 피킹 작업 할당, RF/음성 피킹(Pick-by-Voice) 가이드, 출고 검수 및 포장 관리 |
| 야드 및 도크 관리 | 입출고 차량 스케줄링(Dock Appointment Scheduling), 야드 내 차량/화물 위치 추적 |
| 인력 관리 | 작업자별 생산성 측정, 필요 인력 수요 예측, 작업 가이던스, 게이미피케이션(Gamification) |

### 2.2 WES / MFS

| 기능 그룹 | 세부 기능 |
|---|---|
| 동적 작업 이행 전략 | 웨이브(Wave) 피킹, Waveless(On-Demand) 즉시 처리, 하이브리드 이행 전략 |
| 자재 흐름 제어 | WMS 상위 지시와 WCS 설비 하부 동작 사이의 미들웨어 레이어, 설비 간 흐름 균형 유지 |
| 디지털 트윈/시뮬레이션 | 가상 환경에서 물류 프로세스·설비 제어 로직을 사전 검증하는 에뮬레이션 |

### 2.3 WCS

| 기능 그룹 | 세부 기능 |
|---|---|
| 자동화 설비 직접 제어 | 스태커 크레인(SRM), 컨베이어, 분류기(Sorter), AGV/AMR, 로봇 적재 셀 등 MHE 직접 통신·동작 제어 |
| 고속 분류 제어 | 화물 간격 조정(Carton Gapping), 바코드 고속 스캔, 슈트 Divert 제어, 부하별 자동 가변 속도 제어(Auto Speed Control) |
| 지능형 라우팅/병목 해소 | 설비 몰림 감지·작업 분산 알고리즘, 실시간 장비 상태 분석 기반 경로 재설정·우회(Rerouting) |
| 서열 출고/지능형 적재 | 매장 진열 순서 기반 서열 출고(Sequential Dispatch), 다중 로봇 셀 혼합 팔레타이징(Store-based Palletization), 중량/용적 최적화, 자동 스트레치 필름 포장 연동 |
| 실시간 모니터링/예외 복구 | 설비 동작 현황 가시화, WMS로의 실시간 피드백, 비상 장애 시나리오 기반 실시간 복구 |

### 2.4 차세대 플랫폼 및 AI

| 기능 그룹 | 세부 기능 |
|---|---|
| 에이전틱 AI | 웨이브 미출고 원인 자율 분석·교정 Agent, 인력 불균형 탐지·재배치 Agent, 작업자 디바이스 가이던스 Agent |
| 클라우드 네이티브/무중단 업데이트 | MSA 기반 Versionless(Zero-Downtime) 아키텍처 |
| 감사 기능/확장성 | AI 판단 이력의 자연어 Audit Log 조회, API-First 커스텀 확장(Extension Pack) |

## 3. 벤더 개요

| 벤더 | 분류 | 아키텍처/공급 형태 | 핵심 차별점 |
|---|---|---|---|
| 두산로지스틱스솔루션 | 국내, WMS/WCS | Turnkey SI + 자체 소프트웨어 | OMS/TMS 연계, WCS→WMS 실시간 피드백, 서열 출고 |
| 현대무벡스 | 국내, WCS | 지능형 제어 + IT 컨설팅 통합형 | 병목 해소 알고리즘, 시나리오 기반 실시간 우회 경로 |
| LG CNS/SFA 등 | 국내, WCS/WES | 대규모 물류 인프라 특화 SI | 대용량 트래픽·PLC 레벨 고속 통신 |
| SAP S/4HANA EWM | 해외, WMS/MFS | ERP 통합형(On-Prem·Cloud) | Fiori UX, Yard 관리, 내장 MFS로 PLC/WCS 직접 통신 |
| Manhattan Active WM | 해외, WMS/WES | 100% Cloud-Native MSA(Versionless) | 에이전틱 AI(Wave/Labor/Associate Agent), API-First |
| Dematic iQ | 해외, WES/WCS | 하이브리드 모듈형 | Waveless 제어, QNX RTOS 고속 분류기·로봇 셀 직접 제어 |
| Swisslog SynQ | 해외, WMS/WES/MFS/WCS | 단일 통합 아키텍처 | 디지털 트윈 에뮬레이션, 90분 숙달 가이드형 UI, SAP EWM 표준 연동 |

## 4. 벤더별 세부 기능 스펙

### SAP S/4HANA EWM

- **마스터/포장 관리**: Fiori 앱(Manage Product Master Data), `/SCWM/PACKSPEC`으로 카톤/팔레트 입수량·규격 설정
- **입고/적치**: PO/Delivery 연동, RF 스캔 기반 Handling Unit(HU) 생성, 적치 전략(빈 공간 우선/고정 빈) 기반 최적 빈 자동 계산, 창고 작업(WT) 생성·확정
- **내부 이동/조회**: `/SCWM/ADHU`(HU 이동 즉시 확정), `/SCWM/MON`(실시간 창고 모니터링)
- **부속 기능**: Dock Appointment Scheduling, Slotting, Physical Inventory, 내장 MFS
- **제어 메커니즘**: In-Memory 기반 고속 트랜잭션 처리, 내장 MFS 모듈을 통한 PLC/WCS 직접 데이터 연동(별도 미들웨어 불필요)

### Manhattan Active WM

- **아키텍처**: 100% Cloud-Native, MSA, Versionless(무중단 업그레이드), API-First
- **에이전틱 AI**: Wave Coordinator Agent(웨이브 결품 자율 교정), Labor Agent(인력 불균형 감지·재배치), Associate Agent(작업자 온디바이스 가이던스)
- **통합 UX**: WMS·Labor Management·Slotting Optimization을 단일 터치 UI로 통합
- **개발/감사**: ProActive U-100 Extension Pack 커스텀 개발, 자연어 Audit Log
- **제어 메커니즘**: 마이크로서비스 간 REST API 연동, 머신러닝 기반 작업 시간 예측·AI 자율 제어

### Dematic iQ

- **Optimize(WES)**: Wave/Waveless(On-Demand)/Hybrid 이행 전략, 주문·리소스 최적화, 린(Lean) 프로세스 관리
- **WCS**: QNX RTOS 기반 고속 처리, Carton Gapping, Scanning, Divert Control, Auto Speed Control
- **로봇 팔레타이징 셀**: 15개 로봇 셀 연동, 최대 28종 패키지 혼합 적재, Store-based 순서 적재, 중량/용적 센서 레벨 미세 제어, 실시간 래피드 버퍼 기반 동적 제어
- **기타 연동**: 자동 필름 포장(Stretch Wrapping), Pick-by-Voice

### Swisslog SynQ

- **통합 아키텍처**: WMS·WES·MFS·WCS를 단일 소프트웨어 내 결합
- **디지털 트윈**: 사전 검증용 Emulation & Simulation 도구
- **작업자 UI**: Guided User Workflows(신규자 90분 내 숙달)
- **연동성**: 다중 거점(Multi-site) 지원, SAP EWM end-to-end 표준 연동
- **제어 메커니즘**: 단일 통합 데이터베이스 기반 설비-소프트웨어 제어, 가상 환경 시뮬레이션 기반 운영 최적화

### 두산로지스틱스솔루션

- **WMS 연동**: SCM 내 OMS·TMS 연동, 창고 내 재고 흐름 정밀 추적
- **WCS 피드백**: 설비 통합 제어 결과를 WMS에 실시간 피드백
- **제어 로직**: 보관 위치별 정밀 재고 관리, 서열 출고(Sequential Dispatch) 제어
- **운영 관리**: 실시간 모니터링 화면, 장애 발생 시 빠른 대처
- **제어 메커니즘**: Turnkey SI, 설비 제어 데이터와 상위 WMS 재고 데이터 간 고속 2-Way 피드백 루프

### 현대무벡스

- **지능형 작업 할당**: 설비 간 병목 현상(Bottleneck) 해소 알고리즘, 시간당 처리량(Throughput) 최적화
- **트래킹/정합성**: 표준화 인터페이스 기반 화물 위치/상태 실시간 트래킹
- **유연 장애 대응**: 설비 이상 시 실시간 장비 상태 분석, 작업 경로 재설정·우회(Rerouting) 할당
- **MHE 연동**: SRM, NBS & Singulator, ABES 등 표준 인터페이스 연동
- **제어 메커니즘**: 고속 데이터 처리 기반 실시간 장비 트래픽 분석, 센서 시나리오 기반 자동 우회

## 5. 이 샘플 앱과의 매핑

### 이미 스펙/구현이 있는 영역 (main repo `openspec/changes/supabase-wms-erp-replacement`)

| 카탈로그 영역 | 대응 capability |
|---|---|
| 마스터 데이터 관리 | `wms_master-data` |
| 재고 관리(원장·가용재고) | `wms_inventory-ledger` |
| 재고 관리 > 보충 로직 | `wms_replenishment-planning` |
| (구매) | `wms_purchase-ordering` |
| 입고 및 적치 | `wms_inbound-receiving`, `wms_putaway-transfer` |
| (품질 검사·처분 — 카탈로그에 없는 자체 확장) | `wms_quality-disposition` |
| 출고 및 피킹 | `wms_outbound-fulfillment` |
| (반품 — 카탈로그에 없는 자체 확장) | `wms_return-logistics` |
| (실사 — 카탈로그에 없는 자체 확장) | `wms_cycle-counting` |
| (추적성/GS1 — 카탈로그에 없는 자체 확장) | `wms_traceability-scanning` |
| 창고 작업 실행 전반 | `wms_warehouse-task-execution` |
| (ProcessGPT 연동 — 이 제품 고유) | `wms_process-orchestration`, `wms_tenant-access-control` |
| 실시간 모니터링(WMS 측) | `wms_operations-observability` |

### 카탈로그에는 있지만 아직 스펙이 없는 영역

| 카탈로그 영역 | 비고 |
|---|---|
| 야드 및 도크 관리 (Yard & Dock Management) | **스펙 완료 → `wms_yard-dock-scheduling`** (`openspec/changes/add-yard-dock-scheduling`). 창고별 도크 레지스트리(`wms.docks`)와 입고 PO에 연결된 도크 예약(`wms.dock_appointments`, 시간창+특정 도크)을 신설하고, Postgres `EXCLUDE USING gist` 제약으로 동일 도크의 겹치는 시간창 이중 예약을 DB 레벨에서 원천 차단하며, 차량의 야드 체크인→도킹(도크 점유)→출차(도크 해제)라는 이산 상태 전이를 다룬다. 기존 `wms_register_arrival`은 변경하지 않고 이 계약과 독립적으로 계속 동작한다(예약 없이도 입하 접수 가능) — 실시간 GPS/RTLS 야드 위치추적은 범위 밖이다. **구현 완료**: `supabase/migrations/20260802_yard_dock_scheduling.sql`(테이블 2종, RPC 8종, `btree_gist` 활성화), MCP 도구 8종, 화면 `/inbound/dock-schedule`(`DockScheduleView.vue`), Playwright `dock-schedule-flow.spec.ts`. 스펙 작성 시점과 달리 `wms.outbound_orders`(area5, 20260731)가 실제로 병합되어 있어 `appointment_type='OUTBOUND'`을 연기하지 않고 동작하는 예약 타입으로 구현했다(하드 FK는 여전히 없고 `linked_entity_type='outbound_order'`일 때만 같은 창고 존재 여부를 RPC가 확인) |
| 인력 관리 (Labor Management) | **스펙 완료 → `wms_labor-management`** (`openspec/changes/add-labor-management`). 이 저장소에 범용 작업(task) 모델이 전혀 없다는 정직한 스코프 확인 위에, 작업자가 업무 처리의 시작·완료·중단을 명시적으로 기록하는 인력 활동 로그(`wms.labor_activities`)를 신설하고(기존 `wms.audit_events` 타임스탬프 역산 방식은 행위자 모호성·유휴시간 오염 문제로 기각), 그 로그를 근거로 작업자별·역할별 생산성 집계, 트레일링 평균 처리량 기반 단순 비율 인력 수요 추정(ML 아님), 기간별 생산성 리더보드(포인트/배지 없음)를 제공하며, 개인 데이터는 본인 또는 `WAREHOUSE_MANAGER`/`WMS_ADMIN`만 조회 가능하도록 RLS+RPC 이중 통제한다. 기존 입고/검수/적치 RPC는 시그니처·동작을 변경하지 않는다 — 범용 작업 생명주기 모델(main repo `wms_warehouse-task-execution`)과 Labor Agent류 자율 재배치는 범위 밖이다. **구현 완료**: `supabase/migrations/20260803_labor_management.sql`(테이블 1종, RPC 6종 + 내부 헬퍼 2종, `duration_seconds` 생성 컬럼), MCP 도구 7종(6개 RPC 래퍼 + 계측 패턴 참고 구현 `receive_with_labor_tracking`), 화면 `/labor`(`LaborView.vue`), Playwright `labor-flow.spec.ts`, psql 검증 `openspec/specs/wms_labor-management/e2e/verify.sql`. 스펙 대비 편차 4건은 마이그레이션 헤더 V1~V4에 기록했다 — design.md의 RPC 파라미터 순서가 PostgreSQL 문법상 유효하지 않아 필수 인자를 앞으로 옮긴 점, D4 본문에 맞춰 `WAREHOUSE_MANAGER`도 본인 활동을 기록할 수 있게 한 점, 비관리자 리더보드의 순위를 위조하지도 노출하지도 않고 보류(`rank=null`)한 점, 수요 추정의 처리량 단위를 `unit_count`로 못박고 수량 표본이 없으면 조용히 다른 단위로 갈아타는 대신 `INVALID`을 반환하는 점 |
| 슬롯팅 최적화 (Slotting Optimization) | **스펙 완료 → `wms_slotting-optimization`** (`openspec/changes/add-slotting-optimization`). 이 저장소에 위치/빈 모델이 전혀 없다는 정직한 스코프 확인 위에, 최소 보관 위치 레지스트리(`wms.storage_locations`, 접근성 순위)와 SKU-위치 배정 선언(`wms.sku_location_assignments`, 원장에서 유도되지 않는 운영자 선언값)을 새로 정의하고(Option A), `wms.stock_ledger_entries`의 `AVAILABLE` 상태 음수 `qty_delta`만을 출하 소비 신호로 삼아 SKU별 속도 등급(ABC)을 계산하며, 등급별 목표 접근성 정책과 비교해 재배치 추천을 생성하고 사람 운영자(`WMS_ADMIN`/`WAREHOUSE_MANAGER`)의 승인을 거쳐야만 실제 배정이 바뀌는 HITL 계약을 다룬다. 이 저장소는 현재 `AVAILABLE` 재고를 소비 방향으로 차감하는 RPC가 전혀 없어(정직하게 확인됨) 속도 신호는 오늘 시점에는 항상 비어 있으며, 향후 소비/출고 RPC가 구현되는 순간부터 신호가 채워지는 전진 설계다 — 위치 계층 전체·용량 관리 규칙 엔진·실제 동선 계산·area5 `wms.outbound_orders`에 대한 스키마 의존은 범위 밖이다 |
| WES/MFS 자재 흐름 제어 | **스펙 완료 → `wms_wes-material-flow-control`** (`openspec/changes/add-wes-material-flow-control`). WMS 상위 작업 의도(현재는 `wms.receipts`가 적치 대기 상태에 도달한 것)를 업무 오더로 등록하고, Wave(배치 큐잉·릴리즈)/Waveless(즉시 디스패치) 전략에 따라 `wms_wcs-equipment-control`의 설비 명령으로 번역·디스패치하며, 명령 결과를 업무 오더 상태로 되돌리는 미들웨어 계약을 다룬다. 단순 부하 분산(흐름 균형)만 포함하고, 병목 예측·서열 적재·시뮬레이션 같은 도메인 로직은 후속 스펙(§ 아래 행) 몫이다 |
| 디지털 트윈/시뮬레이션 | **스펙 완료 → `wms_wcs-digital-twin-simulation`** (`openspec/changes/add-wcs-digital-twin-simulation`). `is_simulated=true`로 표시된 설비에 대해 `wms_wcs-equipment-control`의 명령 디스패치 계약을 실제 하드웨어 없이 자동 이행하는 소프트웨어 시뮬레이터를 다룬다 — 설비별 타이밍/실패·잼 주입률 프로파일, 재시작 안전한 명령별 진행 계획, `WCS_GATEWAY`로 인증하는 외부 워커 프로세스(Postgres 스케줄 함수가 아니라 워커를 선택한 이유는 `auth.uid()` 세션 요구사항 — design.md D2)가 area1~5의 명령 결과 보고 경로를 실제로 호출해 그 계약들의 검증·전파 트리거가 시뮬레이션 환경에서도 동일하게 동작하게 한다(WCS/WES 계열 스펙 시리즈의 마지막 항목). 부수적으로, 설비 구성 변경이 예상 완료 시점에 미치는 영향을 같은 타이밍 모델로 추정하는 범위가 좁은 what-if 시나리오 dry-run(실제 명령 디스패치 없음)도 함께 정의한다 — 3D 모션·물리 시뮬레이션(진짜 디지털 트윈), 결정론적 재현, ML 기반 시나리오 자동 탐색은 다루지 않는다 |
| WCS 자동화 설비 직접 제어 | **스펙 완료 → `wms_wcs-equipment-control`** (`openspec/changes/add-wcs-equipment-control-contract`). SRM/컨베이어/분류기/AGV/AMR/로봇 등록·명령 디스패치 계약을 다룬다. 실제 PLC 제어 자체는 여전히 스코프 밖이며, 계약을 실제로 채우는 쪽(실 WCS/PLC 게이트웨이 또는 소프트웨어 시뮬레이터)은 이후 별도로 연결한다 |
| 실시간 모니터링/예외 복구 (WCS 측) | **스펙 완료 → `wms_wcs-equipment-control`**. 설비 상태·이벤트 피드백, 장애 발생 시 진행 중 명령 처리와 사람 확인 기반 복구를 같은 스펙에서 함께 다룬다(§2.3 "실시간 모니터링/예외 복구" 항목 대응). WMS 측 실시간 모니터링(`wms_operations-observability`, §140행)과는 별개다 |
| 고속 분류 제어 (Sortation Logic) | **스펙 완료 → `wms_wcs-sortation-logic`** (`openspec/changes/add-wcs-sortation-logic`). `SORTER`/`CONVEYOR` 설비별 분류 프로파일(화물 간격, 속도 범위, 센서 감지 윈도우)을 새 마스터데이터 테이블로 관리하고, `wms_wcs-equipment-control`의 `command_type`/`payload`를 확장(`DIVERT`, `SET_SPEED`)해 슈트 라우팅과 속도 조정 명령의 구조화된 payload 계약을 정의하며, 분류 결과(성공/오분류/잼)를 명령 결과 보고에 매핑하고 잼 발생 시 자동으로 설비 장애를 승격시키는 계약을 다룬다. 병목 감지·재라우팅, 서열 적재, 디지털 트윈은 후속 스펙(§ 아래 행) 몫이다 |
| 지능형 라우팅/병목 해소 | **스펙 완료 → `wms_wcs-bottleneck-routing`** (`openspec/changes/add-wcs-bottleneck-routing`). `wms_wcs-equipment-control`의 명령 큐·장애 이력을 관찰해 큐 길이·최근 장애 빈도 임계값으로 병목 설비를 판정하고(뷰 기반, 이력 저장 없음), `wms_wes-material-flow-control`의 "가용 설비 선택과 흐름 균형" 단계에 하드 제외(강제 제외 목록)와 소프트 회피(병목 폴백)를 반영하는 내부 함수 훅을 정의하며, 운영자의 계획 정비용 수동 강제 제외/해제를 다룬다. ML 기반 예측이나 물리적 경로 재계산은 다루지 않는다 — 서열 적재·디지털 트윈은 후속 스펙(§ 아래 행) 몫이다 |
| 서열 출고/지능형 적재 | **스펙 완료 → `wms_wcs-sequential-dispatch`** (`openspec/changes/add-wcs-sequential-dispatch`). 이 저장소에 출고(outbound) 스키마가 전혀 없다는 정직한 스코프 확인 위에, main repo `wms_outbound-fulfillment`의 극히 축소된 최소 출고 단위(`wms.outbound_orders`)를 새로 정의하고, `wms_wes-material-flow-control`의 디스패치 웨이브 안에서 서열 위치(`sequence_position`)·목표 팔레트(`target_pallet_code`)를 배정하며, `wms_wcs-equipment-control`의 `command_type`/`payload`를 확장(`PALLETIZE`, `WRAP`)해 `ROBOT_CELL` 대상 혼합 팔레타이징·중량/용적 상한 검증·스트레치 포장 명령 계약을 정의하고, 팔레타이징 결과를 명령 결과 보고에 매핑해 항목 단위로 서열 배정 상태를 되돌리는 계약을 다룬다. 재고 할당/예약·피킹·포장출하확정·출고취소(정식 `wms_outbound-fulfillment` 몫)와 디지털 트윈은 다루지 않는다 |
| 에이전틱 AI | **스펙 완료 → `wms_agentic-operations`** (`openspec/changes/add-agentic-operations`). "ProcessGPT 자체가 에이전트 오케스트레이션을 담당하므로 매핑 방식 논의 필요"였던 미결 논의를 결론지었다 — Manhattan Active WM처럼 에이전트를 WMS 내부에 내장하는 대신, 모든 오케스트레이션·자율 판단·HITL을 여전히 ProcessGPT에 맡기고 이 저장소는 ProcessGPT 쪽 외부 에이전트(`PROCESS_AGENT`)가 Wave Coordinator/Labor/Associate 역할을 대신할 수 있도록 신호(읽기 RPC)·액션 허용/거부 경계·판단 근거 기록만 제공한다. 디스패치 지연·설비 병목 신호(`wms_get_dispatch_delay_signals`)는 `wms_wes-material-flow-control`+`wms_wcs-bottleneck-routing`을, 인력 불균형 신호(`wms_get_labor_balance_signals`)는 `wms_labor-management`의 생산성 집계를 감싸며, 자율 실행 판단 근거와 사람 승인이 필요한 제안(인력 재배치, 라우팅 제외 제안 등) 모두 새 companion 테이블 `wms.agent_decisions`(`LOGGED`/`PROPOSED`/`CONFIRMED`/`REJECTED`)가 소유한다 — `wms.audit_events`에는 컬럼을 추가하지 않으며, `wms_operations-audit-log`가 이 테이블을 `correlation_id`로 조인해 자연어 감사 로그에 판단 근거를 포함시키는 소비자로 동작한다(두 변경이 상호 검토 끝에 수렴한 결론). DB 내 ML 모델, Postgres 자율 스케줄링 루프, 두 번째 BPM 엔진, 제안의 자동 실행은 다루지 않는다. **구현 완료**: `supabase/migrations/20260805_agentic_operations.sql`(테이블 1종, RPC 8종 + 내부 헬퍼 1종), MCP 도구 8종(그중 `PROCESS_AGENT` 허용은 6종), 화면 `/agent/decisions`(`AgentDecisionsView.vue`), Playwright `agent-decisions-flow.spec.ts`, psql 검증 `openspec/specs/wms_agentic-operations/e2e/verify.sql`. **design.md가 "스펙만 완료, DB 미구현"으로 전제했던 선행 영역 3종(areas 2·4·8)이 그 사이 모두 실제로 구현되어 tasks.md §5의 분리 착수 조건이 해소됐고, 두 신호 RPC를 그 영역들의 실제 스키마에 맞춰 같은 마이그레이션에 함께 구현했다** — 실제 스키마와 design.md 추정의 차이 8건은 마이그레이션 헤더 V1~V8에 기록했다. 대표적으로 `wms_get_labor_productivity`는 비관리자 호출자를 `scope='SELF'`로 강제 축소하므로 그대로 감싸면 에이전트가 자기 행 하나만 보게 되어(D2의 역할 확장이 무의미해져) 같은 집계 술어를 창고 스코프로 다시 쓴 점(V1), `wms.wcs_equipment_bottleneck_status`가 설비 단위 뷰라 QUEUED 업무 오더와 직접 조인할 수 없어 실제 선택 훅과 같은 술어로 후보 설비 집합을 만들어 조인하고 지연 원인을 배열로 반환한 점(V4, 미릴리스 웨이브는 `WAVE_NOT_RELEASED`로 구분해 "지연이 아님"을 명시), `wms.receipts`에 담당자 컬럼이 없어 관여 여부를 감사 이벤트·품질 판정·폐기 판정·인력 활동 4곳의 합집합으로 유도하고 `involvement_sources`로 노출한 점(V5) |
| 클라우드 네이티브 Versionless | 배포 아키텍처 — 스펙보다는 design 영역 |
| 자연어 Audit Log | **스펙 완료 → `wms_operations-audit-log`** (`openspec/changes/add-operations-audit-log`). 확인 결과 `wms_operations-observability`는 이 저장소에 스펙/구현이 없어(main repo에만 표기, 미체크아웃) 그 확장이 아니라 독립 계약으로 신설했다. 이미 모든 쓰기 RPC가 구조화해 기록 중인 `wms.audit_events`(`command`/`entity_type`/`before`/`after`) 위에, DB 내부 LLM 호출 없이 결정론적 `CASE`/템플릿으로 한국어 요약을 생성하는 `wms.describe_audit_event` 함수와, `WMS_ADMIN`/`AUDITOR`(기존에 예정만 되어 있던 미사용 역할) 전용 조회·내보내기 RPC(`wms_query_audit_log`, `wms_export_audit_log`)를 추가한다. `wms.audit_events`에는 컬럼을 추가하지 않는다 — 작업 도중 동시에 생성된 `openspec/changes/add-agentic-operations`가 에이전트 판단 근거 전용 companion 테이블 `wms.agent_decisions`를 이미 소유하기로 결정해 두었으므로, 이 계약은 그 테이블을 `correlation_id`로 조인해 소비하는 2단계 구현으로 경쟁을 피했다. **구현 완료** — `supabase/migrations/20260806_operations_audit_log.sql`(함수 3개, 신규 테이블 0개), 화면 `/operations/audit-log`, MCP 도구 2종(`PROCESS_AGENT` 허용 목록에서는 제외), 요약 템플릿 커버리지 65/65 명령 + 범용 폴백. `add-agentic-operations`가 먼저 구현되어 있어 1·2단계를 한 마이그레이션에 합쳤다. 검증 기록은 `openspec/specs/wms_operations-audit-log/e2e/README.md` |

design.md §3 "제외 범위"는 "자동창고 설비 PLC/WCS의 저수준 제어"를 명시적으로 1차 범위 밖으로
뒀다 — 따라서 WCS 관련 영역은 스펙화하더라도 **PLC 직접 제어가 아니라 WMS-WCS 간 계약
(명령·이벤트·상태 피드백)** 수준으로 잡는 것이 design.md와 일관된다.

## 6. 다음 단계

사용자가 지정하는 영역부터 순서대로 `openspec/specs/wms_<domain>-<feature>/spec.md`를
작성한다(이 저장소 `openspec/config.yaml`의 네이밍 규칙 참고). 후보 목록은 §5의
"아직 스펙이 없는 영역" 표를 그대로 사용한다.
