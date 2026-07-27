# 10.3–10.5 연동: wms-mcp를 ProcessGPT 테넌트에 등록

> `mcp/` 서버의 9개 도구와 ProcessGPT 폴링 컨테이너에서의 도구 검색을 실제로
> 검증했다. `scripts/install_processgpt_integration.py`는 테넌트 MCP 설정, 제한된
> WMS 실행 에이전트, `wms_replenishment_process` BPMN과 HITL 폼을 반복 실행 가능한
> 방식으로 설치한다.

## 실사 결과 요약 (docs/02-contracts.md §1.3)

`services/completion`은 Odoo를 별도 서비스가 아니라 테넌트별 `tenants.mcp`
JSONB 컬럼의 stdio MCP 서버 항목으로 등록해 사용한다
(`services/completion/mcp.json`의 `"odoo ERP"` 항목, 실행은
`services/completion/polling_service/mcp_processor.py`의
`MultiServerMCPClient`를 통해 이뤄진다). wms-mcp는 stdio가 아니라
streamable-HTTP 서버이므로, `mcpServers` 항목의 transport만 다르고
등록 방식은 동일하다.

## 등록 JSON

`tenants.mcp` (또는 `services/completion/mcp.json` 카탈로그)에 아래 항목을 추가한다.

```json
{
  "wms": {
    "type": "url",
    "url": "http://wms-mcp:8199/mcp",
    "transport": "streamable_http"
  }
}
```

로컬 개발 시 `url`은 `http://127.0.0.1:8199/mcp`. docker-compose에 편입할 때는
`services/frontend/docker-compose/docker-compose.yaml`의 기존 서비스들과 같은
패턴으로 `wms-mcp` 서비스를 추가하고(이미 사용 중인 포트와 겹치지 않게 8199 선택,
실사 결과 참고), 컨테이너 이름으로 `url`을 가리키게 한다.

## 에이전트 tool 허용 목록

해당 테넌트의 자동화 에이전트(예: "재보충 담당 에이전트")가 아래 도구만 쓰도록
scope를 제한한다(design.md D6, §12 `PROCESS_AGENT` 원칙):

```text
wms.get_availability
wms.create_rfq
wms.request_approval
wms.confirm_po
wms.register_arrival
wms.receive
wms.putaway

# WCS 설비 제어 계약 (wms_wcs-equipment-control) 중 PROCESS_AGENT가
# 실제로 호출 가능한 도구만
wms.dispatch_equipment_command
wms.cancel_equipment_command
wms.get_equipment_status

# WES/MFS 자재 흐름 제어 계약 (wms_wes-material-flow-control) — 6개 전부
wms.open_dispatch_wave
wms.create_work_order
wms.release_dispatch_wave
wms.retry_work_order_dispatch
wms.cancel_work_order
wms.get_work_order_status

# 고속 분류 제어 계약 (wms_wcs-sortation-logic) 중 PROCESS_AGENT가
# 실제로 호출 가능한 도구만 (프로파일 쓰기는 PROCESS_AGENT 권한 밖)
wms.get_sortation_profile

# 지능형 라우팅/병목 해소 계약 (wms_wcs-bottleneck-routing) 중 읽기 하나만
# (임계값 조정·강제 제외는 사람의 운영 판단이라 PROCESS_AGENT 권한 밖)
wms.get_equipment_routing_status

# 서열 출고/지능형 적재 계약 (wms_wcs-sequential-dispatch) — 6개 전부
wms.create_outbound_order
wms.assign_dispatch_sequence
wms.cancel_dispatch_sequence
wms.dispatch_palletize_command
wms.get_dispatch_sequence_status
wms.get_pallet_manifest

# 디지털 트윈/시뮬레이션 계약 (wms_wcs-digital-twin-simulation) 중
# PROCESS_AGENT가 실제로 호출 가능한 도구만 — what-if 시나리오(정의·실행·조회)와
# 프로파일 조회뿐이다. 명령 계획 수립/진행 보고 도구는 WCS_GATEWAY 전용이고,
# 시뮬레이션 모드 전환과 프로파일 쓰기는 사람의 운영 판단이라 권한 밖이다.
wms.create_simulation_scenario
wms.run_simulation_scenario
wms.get_simulation_scenario_status
wms.get_simulation_profile

# 야드/도크 관리 계약 (wms_yard-dock-scheduling) 중 PROCESS_AGENT가
# 실제로 호출 가능한 도구만 — 슬롯 예약·취소와 스케줄 조회뿐이다.
# 차량의 물리적 이동(체크인/도킹/출차)과 도크 레지스트리·정비는 권한 밖이다.
wms.schedule_dock_appointment
wms.cancel_dock_appointment
wms.get_dock_schedule

# 인력 관리 계약 (wms_labor-management) 중 PROCESS_AGENT가 실제로 호출 가능한
# 도구만 — 자기 자신의 활동 계측 3종과, 자기 자신의 처리량 조회뿐이다.
# 리더보드는 비관리자에게 본인 행 하나만 돌려주므로 뺐고, 인력 수요 추정은
# 관리자 전용이라 뺐다.
wms.start_labor_activity
wms.complete_labor_activity
wms.cancel_labor_activity
wms.get_labor_productivity
wms.receive_with_labor_tracking

# 슬롯팅 최적화 계약 (wms_slotting-optimization) 중 PROCESS_AGENT가 실제로
# 호출 가능한 도구만 — 원장을 읽어 통계를 내는 분석 2종뿐이다. 추천 승인/반려와
# 적용은 물리적 재고 이동을 유발하는 사람의 결정이라 뺐고, 위치 레지스트리와
# 등급 정책은 마스터데이터라 뺐다(register_equipment / register_dock와 동일).
wms.compute_sku_velocity
wms.generate_slotting_recommendations

# 에이전틱 운영 계약 (wms_agentic-operations) 중 PROCESS_AGENT가 실제로 호출
# 가능한 도구만 — 읽기 신호 4종과, 자기가 무엇을 왜 했는지 남기는 기록 2종.
# 제안의 승인/거부는 이 계약의 존재 이유이므로 에이전트에게 열지 않는다.
wms.get_labor_balance_signals
wms.get_dispatch_delay_signals
wms.get_worker_next_actions
wms.get_agent_decisions
wms.log_agent_decision
wms.propose_agent_action

# 아래 2개는 허용 목록에 넣지 않는다 — PROCESS_AGENT가 호출하면 역할 검사에서
# FORBIDDEN이 반환된다(design.md D6, 안전망이 DB 레벨에도 있다)
# wms.confirm_agent_proposal
# wms.reject_agent_proposal

# 자연어 감사 로그 계약 (wms_operations-audit-log)의 도구 2종도 허용 목록에
# 넣지 않는다. 이 둘은 AUDITOR 서비스 아이덴티티로 로그인하며, RPC 자체가
# WMS_ADMIN/AUDITOR만 받으므로 PROCESS_AGENT로는 애초에 호출되지 않는다.
# wms.query_audit_log
# wms.export_audit_log
```

`wms.inspect`(품질 판정)와 `wms.scrap`(폐기)은 RLS에서 이미
`QUALITY_INSPECTOR`/`WMS_ADMIN` 역할만 허용하도록 막혀 있다 — 자동 에이전트가
호출해도 `FORBIDDEN`이 반환된다(migration `wms_record_quality_result`/
`wms_apply_disposition`). 즉 tool 허용 목록에서 빼더라도, 빠졌을 때의 안전망이
DB 레벨에도 있다.

> **note (WCS 설비 제어)**: 같은 이유로 아래 4개 도구는 허용 목록에서 **제외**한다.
> `wms.register_equipment`는 `WMS_ADMIN`/`WAREHOUSE_MANAGER`(설비 레지스트리 관리),
> `wms.resolve_equipment_fault`는 `WCS_OPERATOR`/`WAREHOUSE_MANAGER`/`WMS_ADMIN`
> (장애 해소는 현장 확인을 거친 사람의 판단)만 허용된다.
> `wms.report_command_result`와 `wms.report_equipment_status`,
> `wms.raise_equipment_fault`는 설비 쪽 service identity(`WCS_GATEWAY`)의 몫이라
> `PROCESS_AGENT`에게는 `FORBIDDEN`이다 — 명령을 **내리는** 쪽과 결과를
> **보고하는** 쪽을 RLS에서 분리한다(design.md D5). MCP 서버는 이 세 도구만
> 별도의 `WMS_WCS_GATEWAY_EMAIL`/`PASSWORD` 자격으로 로그인해 호출한다
> (`mcp/wms_mcp/client.py`의 `get_gateway_client`). 실제 PLC 게이트웨이를 붙일
> 때는 그 자격증명에 `WCS_GATEWAY` 역할만 부여하면 사고 반경이 좁아진다.

> **note (WES 자재 흐름 제어)**: 위 WCS 계약과 달리, 이 계약에는 설비 쪽 전용
> RPC가 하나도 없다 — 웨이브를 열고, 업무 오더를 만들고, 릴리즈·재시도·취소를
> 판단하는 주체는 언제나 WMS 내부 오케스트레이션이다(design.md D4: 새 service
> role을 추가하지 않는다). 따라서 6개 도구 전부가 `PROCESS_AGENT` 허용 목록에
> 들어간다. 업무 오더가 실제로 완료되려면 설비 쪽이 area 1의
> `wms.report_command_result`를 호출해야 하고, 그 순간 이 계약의 완료 전파
> 트리거가 업무 오더 상태를 자동으로 따라 올린다 — 에이전트가 폴링하며 상태를
> 되돌릴 필요가 없다.
>
> 쓰기 RPC의 허용 역할은 `WAREHOUSE_MANAGER`/`WCS_OPERATOR`/`PROCESS_AGENT`로,
> `wms_dispatch_equipment_command`가 실제로 허용하는 집합과 정확히 일치시켰다
> (design.md D3). `WMS_ADMIN`은 그 RPC의 허용 목록에 없기 때문에 이 계약에서도
> 제외했다 — 넣었다면 "업무 오더 등록은 성공했는데 내부 디스패치만 FORBIDDEN"이
> 되는 부분 실패가 생긴다. 재현 결과는
> `openspec/specs/wms_wes-material-flow-control/e2e/README.md` 참고.

> **note (고속 분류 제어)**: 이 계약은 새 명령 도구를 만들지 않는다 — `DIVERT`와
> `SET_SPEED`는 위 `wms.dispatch_equipment_command`에 `command_type`과 payload로
> 실어 보내고, 결과는 `wms.report_command_result`의 `detail.outcome`
> (`SUCCESS`/`MISROUTE`/`JAM`)으로 되돌아온다. 그래서 새로 추가된 도구는 프로파일
> 3종뿐이고, 그중 허용 목록에 들어가는 것은 읽기 전용 `wms.get_sortation_profile`
> 하나다. `wms.create_sortation_profile`/`wms.update_sortation_profile`은
> `WMS_ADMIN`/`WAREHOUSE_MANAGER`/`WCS_OPERATOR`만 허용되므로 `PROCESS_AGENT`로
> 호출하면 `FORBIDDEN`이 반환된다(설비 튜닝은 운영 책임자의 판단).
>
> `get_sortation_profile`이 반환하는 프로파일(최소 간격, 속도 범위, 단위)이 곧
> 분류 명령 payload의 계약이다 — 에이전트는 명령을 보내기 전에 이 도구로 범위를
> 확인해야 하고, 범위를 벗어난 속도나 필수 필드가 빠진 Divert는
> `dispatch_equipment_command`가 `INVALID`로 거부한다(payload 검증은 DB 트리거).
> 프로파일이 없는 설비에는 분류 명령 자체를 보낼 수 없다. `JAM`이 보고되면 설비
> 장애가 자동 승격되므로 에이전트가 별도로 장애를 신고할 필요가 없고, 그 해소는
> 사람(`WCS_OPERATOR` 등)의 몫이다. 재현 결과는
> `openspec/specs/wms_wcs-sortation-logic/e2e/README.md` 참고.

> **note (지능형 라우팅/병목 해소)**: 이 계약의 신규 도구 5종 중 `PROCESS_AGENT`
> 허용 목록에 들어가는 것은 읽기 전용 `wms.get_equipment_routing_status` 하나뿐이다.
> 나머지 4종(`wms.register_wcs_routing_policy`, `wms.update_wcs_routing_policy`,
> `wms.exclude_equipment_from_routing`, `wms.clear_equipment_routing_exclusion`)은
> `WMS_ADMIN`/`WAREHOUSE_MANAGER`(임계값)와 여기에 `WCS_OPERATOR`를 더한 집합
> (강제 제외)만 허용하므로 `PROCESS_AGENT`로 호출하면 `FORBIDDEN`이 반환된다 —
> 임계값 튜닝과 설비를 라인에서 빼는 판단은 사람의 몫이라는 design.md 역할 모델을
> 그대로 구현한 것이다(장애 해소가 사람 전용인 것과 같은 원칙).
>
> 흥미로운 점은 에이전트가 이 계약을 **건드리지 못하면서도 혜택은 그대로 받는다**는
> 것이다. 병목 회피와 강제 제외는 area 2의 `wms.create_work_order` /
> `wms.release_dispatch_wave` / `wms.retry_work_order_dispatch` 안에서
> 자동으로 적용되므로, 에이전트는 기존 도구를 그대로 호출하면 되고 새로 할 일이
> 없다 — 라우팅 전용 명령 도구는 만들지 않았다. 내부 후보 선택 함수
> `wms.wcs_select_available_equipment`도 MCP 도구로 노출하지 않으며,
> `authenticated`에 `EXECUTE` 권한이 없다.
>
> `get_equipment_routing_status`는 에이전트가 "왜 이 업무 오더가 QUEUED로 남았나"를
> 스스로 설명할 수 있게 해 주는 도구다 — `NO_EQUIPMENT_AVAILABLE` 경고를 받았을 때
> 이 도구로 조회하면 각 설비의 `is_excluded`(사람이 뺐다) / `is_bottleneck`(신호가
> 나쁘다) / `routable`을 구분해서 볼 수 있다. 다만 제외를 푸는 것은 사람이 해야
> 한다. 재현 결과와 구현 중 발견한 선행 계약과의 불일치 4건은
> `openspec/specs/wms_wcs-bottleneck-routing/e2e/README.md` 참고.

> **note (서열 출고/지능형 적재)**: 앞의 두 WCS 계약과 달리 이 계약의 신규 도구
> 6종은 **전부** `PROCESS_AGENT` 허용 목록에 들어간다 — 출고 단위를 등록하고,
> 서열을 매기고, 팔레타이징을 지시하는 것은 모두 상위 오케스트레이션의 판단이지
> 사람만의 현장 판단이 아니기 때문이다(WES 자재 흐름 제어와 같은 성격).
>
> 다만 역할 경계가 두 군데 미묘하게 다르다. ① `wms.create_outbound_order`는
> `WCS_OPERATOR`를 제외한다(출고 단위 생성은 상위 업무 판단). ②
> `wms.dispatch_palletize_command`는 반대로 `WMS_ADMIN`을 제외한다 — 내부적으로
> `wms_dispatch_equipment_command`를 호출하는데 그 RPC의 허용 집합에 `WMS_ADMIN`이
> 없어서, 넣었다면 "서열 조회·구성은 끝났는데 실제 명령만 FORBIDDEN"이 되는 부분
> 실패가 생긴다(WES 계약이 겪은 것과 같은 함정). 화면에서도 `WMS_ADMIN`에게는
> 명령 폼을 감추고 안내 문구를 띄운다.
>
> 새 명령 도구는 `dispatch_palletize_command` 하나뿐이다. `WRAP` 디스패치와
> `PALLETIZE`/`WRAP` 결과 보고는 기존 `wms.dispatch_equipment_command` /
> `wms.report_command_result`를 그대로 쓴다(고속 분류 제어의 `DIVERT`/`SET_SPEED`와
> 같은 방식). `PALLETIZE` 결과의 `detail`은 전체 `outcome`
> (`SUCCESS`/`PARTIAL`/`OVERWEIGHT`/`OVERVOLUME`/`ABORTED`)에 더해 **항목별 배열**
> `loaded_items`(`dispatch_sequence_id`, `load_position`, `item_outcome`:
> `LOADED`/`SKIPPED`)를 요구한다 — 명령 하나가 여러 서열 배정을 태우기 때문이다.
> 보고가 정합성 검증을 통과하면 각 서열 배정과 그 출고 단위가 **항목 단위로**
> COMPLETED/FAILED로 자동 전파되므로, 에이전트가 폴링하며 상태를 되돌릴 필요가 없다
> (WES 계약의 명령 단위 완료 전파를 항목 단위로 일반화한 것).
>
> 중량/용적 상한은 두 시점에서 서로 다른 실패를 잡는다 — 디스패치 시점(선언값 합계
> vs 상한)은 "계획을 잘못 짰다"를 `INVALID`로, 결과 보고 시점(`outcome=OVERWEIGHT`/
> `OVERVOLUME`)은 "실물이 선언값과 달랐다"를 사후로 보고한다. 상품 중량·용적
> 마스터데이터가 이 저장소에 없어 선언값이 호출자 입력이므로, 두 값의 편차가 곧
> 데이터 품질 신호다(`get_pallet_manifest`가 나란히 보여 준다). 재현 결과는
> `openspec/specs/wms_wcs-sequential-dispatch/e2e/README.md` 참고.

> **note (야드/도크 관리)**: 신규 도구 8종 중 허용 목록에 들어가는 것은 3종
> (`schedule_dock_appointment`, `cancel_dock_appointment`, `get_dock_schedule`)
> 이고, 나머지 5종은 **제외**한다.
> `wms.register_dock`과 `wms.set_dock_status`는 `WMS_ADMIN`/`WAREHOUSE_MANAGER`
> 전용이다(설비 레지스트리와 같은 성격 — `wms.register_equipment`가 제외된 것과
> 같은 이유).
> `wms.check_in_vehicle` / `wms.dock_vehicle` / `wms.depart_vehicle`는
> `INBOUND_OPERATOR`/`WMS_ADMIN`만 허용된다. 이 세 도구가 주장하는 사실은
> "트럭이 **물리적으로** 야드에 들어왔다 / 도크에 붙었다 / 떠났다"이고, 그것은
> 게이트 요원·현장 담당자가 눈으로 본 것을 기록하는 행위다 — 에이전트에게
> 열어 주면 실물 차량이 움직이지 않았는데 도크가 OCCUPIED로 잠기거나 반대로
> 점유 중인 도크가 풀리는 사고가 난다(design.md D5). WCS 계약이 "명령을 내리는
> 쪽"과 "결과를 보고하는 쪽"을 나눈 것과 같은 원칙을 사람/에이전트 축으로
> 적용한 것이다. RLS에도 같은 제한이 걸려 있어, 허용 목록에서 빠뜨려도
> `FORBIDDEN`이 반환된다(안전망 이중화).
>
> 대신 에이전트가 **할 수 있는** 일은 분명하다: `get_dock_schedule`로 빈 슬롯을
> 찾고, `schedule_dock_appointment`로 PO에 슬롯을 잡고, 공급사 일정이 바뀌면
> `cancel_dock_appointment`로 놓아 준다. 겹치는 시간창은 Postgres exclusion
> 제약이 원자적으로 거부하므로(`CONFLICT`), 에이전트가 "비어 있나 먼저 조회"
> 하고 나서 예약해도 그 사이에 끼어든 다른 예약 때문에 이중 예약이 생기지
> 않는다 — 조회는 UX이고 보장은 DB가 한다. 취소된 예약은 겹침 판정에서 즉시
> 빠지므로 같은 슬롯을 바로 다시 잡을 수 있다.
>
> 이 계약은 기존 `wms.register_arrival`을 **감싸지도 대체하지도 않는다**
> (design.md D2). 도크 예약이 없어도, 예약이 `SCHEDULED`에 머물러 있어도
> `register_arrival`은 그대로 성립한다 — 두 도구는 서로의 전제조건이 아니다.
> 권장 운영 순서(체크인 → 도킹 → `register_arrival` → 출차)는 매뉴얼의 안내
> 이지 DB 제약이 아니다. 재현 결과는
> `openspec/specs/wms_yard-dock-scheduling/e2e/README.md` 참고.

> **note (인력 관리)**: 신규 도구 7종 중 허용 목록에 들어가는 것은 5종이고
> (`start_labor_activity`, `complete_labor_activity`, `cancel_labor_activity`,
> `get_labor_productivity`, `receive_with_labor_tracking`),
> `get_labor_leaderboard`와 `forecast_labor_demand`는 **제외**한다.
>
> 이 계약은 앞의 일곱 영역과 역할 경계를 긋는 방식이 다르다. 앞선 계약들은
> "이 도구를 에이전트가 호출할 수 있는가"를 물었지만, 여기서는 세 개의 쓰기
> 도구를 에이전트가 **자기 자신에 대해서만** 호출할 수 있다 — 시작·완료·취소
> RPC는 `p_actor_id`가 `auth.uid()`와 같은지 검증하고(design.md D2),
> `WMS_ADMIN`만 예외다. MCP 도구에는 남의 명의를 지정할 파라미터 자체가 없다.
> 생산성 수치가 이 계약의 산출물이라, 대리 기록을 허용하면 리더보드와 집계가
> 바로 오염되기 때문이다. 에이전트가 대행한 업무는
> `actor_role='PROCESS_AGENT'`로 집계되므로 사람 처리량과 섞이지 않는다.
>
> 읽기 쪽에서 스펙이 실제로 저울질한 질문은 "에이전트가 **다른 작업자의**
> 생산성을 볼 수 있어야 하는가"였고, 결론은 아니오다. `PROCESS_AGENT`는
> `WAREHOUSE_MANAGER`가 아니므로 `get_labor_productivity`는
> `scope='SELF'`로 **본인 행만** 돌려준다. 중요한 것은 이것이 `FORBIDDEN`이
> **아니라 조용한 필터링**이라는 점이다(design.md D3) — "내 처리량이 궁금해서
> 호출했는데 403이 난다"는 경험을 만들지 않기 위해서다. 그래서
> `get_labor_productivity`는 허용 목록에 남는다(에이전트가 자기 처리량을
> 관찰하는 것은 정당하다). 반대로 `get_labor_leaderboard`는 비관리자에게
> 본인 행 하나만, 그것도 `rank`를 null로 돌려주므로 에이전트가 얻을 정보가
> 사실상 없어 목록에서 뺐다. `forecast_labor_demand`는
> `WAREHOUSE_MANAGER`/`WMS_ADMIN` 전용이라 호출하면 `FORBIDDEN`이다
> (design.md D4: "내일 몇 명이 필요한가"는 관리 판단) — 안전망 이중화.
>
> `receive_with_labor_tracking`은 design.md D1의 계측 패턴 참고 구현 1개다.
> `start_labor_activity` → 기존 `wms_receive` → `complete_labor_activity`
> 순서로 감싸며, **기존 RPC는 한 줄도 고치지 않았다** — 계측 없이
> `receive`만 호출해도 입고는 그대로 성립한다(계약이 강제하지 않는다).
> 입고가 실패하면 열어 둔 활동은 완료가 아니라 취소되고(하지 않은 일이 통계에
> 남지 않게), 반대로 계측 호출이 실패해도 입고는 성공한 그대로 두고 경고만
> 돌려준다(계측이 원장을 되돌리지 않는다). 나머지 네 도구
> (`register_arrival`, `inspect`, `apply_disposition`, `create_putaway_tasks`)의
> 같은 래퍼는 후속 작업으로 남겼다.
>
> 이 계약은 area 1~7 어디에도 의존하지 않고, 입고/검수/적치 RPC의 시그니처와
> 동작도 전혀 바꾸지 않는다. 그 직교성은 `verify.sql` §J가 계측을 하나도
> 걸지 않은 receipt으로 전체 체인을 걸어 보는 것으로 회귀 방지된다. 재현
> 결과는 `openspec/specs/wms_labor-management/e2e/README.md` 참고.

> **note (슬롯팅 최적화)**: 신규 도구 10종 중 허용 목록에 들어가는 것은 2종
> (`compute_sku_velocity`, `generate_slotting_recommendations`)뿐이고, 나머지
> 8종은 **제외**한다.
>
> 이 계약의 역할 경계는 한 문장으로 요약된다 — **분석은 에이전트가, 이동
> 결정은 사람이**(design.md D6). 속도 계산은 `wms.stock_ledger_entries`를
> 읽어 통계를 내는 일이고 추천 생성은 그 통계를 정책과 대조하는 일이다.
> 둘 다 배정을 바꾸지 않으므로 무인 실행이 안전하다. 반면
> `review_slotting_recommendation`(승인/반려)은 지게차가 실제로 움직이게
> 만드는 운영 판단이라 `WMS_ADMIN`/`WAREHOUSE_MANAGER`만 허용하고,
> `apply_slotting_recommendation`은 거기에 `INBOUND_OPERATOR`를 더한다 —
> **옮기라고 결정하는 것**과 **옮겼다고 기록하는 것**은 다른 일이고 후자만
> 현장의 몫이라는 구분이다. `PROCESS_AGENT`는 둘 다 `FORBIDDEN`이다.
> 야드/도크 계약이 "트럭이 물리적으로 움직였다"는 주장을 에이전트에게
> 열어 주지 않은 것과 같은 원칙이다.
>
> 위치 레지스트리(`register_storage_location`, `set_storage_location_status`)와
> 등급 정책(`register_slotting_class_policy`,
> `update_slotting_class_policy`)은 `WMS_ADMIN`/`WAREHOUSE_MANAGER` 전용
> 마스터데이터다 — `register_equipment`, `register_dock`가 제외된 것과 같은
> 이유. SKU-위치 배정 선언/재배정(`assign_sku_location`,
> `reassign_sku_location`)은 "이 SKU가 지금 실제로 어디 있다"는 **현장 관찰
> 진술**이고, 원장에 위치 축이 없어 시스템이 검증할 방법이 전혀 없다 —
> 에이전트에게 열어 주면 아무도 확인하지 않은 배치도가 만들어진다.
>
> 에이전트가 이 계약에서 **할 수 있는** 일은 분명하다: 관찰 윈도우를 잡아
> `compute_sku_velocity`로 ABC 등급 배치를 만들고,
> `generate_slotting_recommendations`로 사람이 검토할 큐를 채워 놓는 것.
> 정책을 바꿔 가며 같은 배치로 여러 번 생성해 보는 것도 가능하다(스냅샷이
> 남아 있어 원장을 다시 훑지 않는다).
>
> **에이전트가 반드시 읽어야 할 응답 필드가 하나 있다**:
> `compute_sku_velocity`의 `skipped_no_data_count`. 이 계약은 소비 신호가
> 없는 SKU에 임의 등급을 매기지 않고 스냅샷 자체를 만들지 않는다. 그리고
> 오늘 이 저장소에는 그 신호를 만드는 코드 경로가 **하나도 없다** —
> `AVAILABLE` 상태에 음수 `qty_delta`를 쓰는 RPC가 없기 때문이다(입고는 QC에
> +, 처분은 QC에 -와 AVAILABLE/SCRAP에 +). area5의 `wms.outbound_orders`는
> 실제로 구현되어 `COMPLETED`까지 가지만 원장을 전혀 건드리지 않으므로
> 이 공백을 메우지 않는다. 따라서 실데이터로 호출하면 `status='NO_SIGNAL'`,
> `included_product_count=0`이 정상이며 결함이 아니다. 향후 출고 차감 RPC가
> 생기면 이 계약은 수정 없이 실제 신호를 내기 시작한다. 재현 결과는
> `openspec/specs/wms_slotting-optimization/e2e/README.md` 참고.

> **note (에이전틱 운영)**: 신규 도구 8종 중 허용 목록에 들어가는 것은 6종
> (읽기 4종 + `log_agent_decision` + `propose_agent_action`)이고,
> `confirm_agent_proposal`과 `reject_agent_proposal`은 **제외**한다.
>
> 앞의 아홉 영역은 각자 "이 도구를 에이전트가 호출해도 되는가"를 개별적으로
> 판단해 왔다. 이 계약은 그 판단들을 바꾸지 않는다 — 오히려 **그 경계를 계약의
> 1급 개념으로 끌어올린다**. 이 저장소에는 에이전트 런타임이 없고 앞으로도
> 두지 않는다(design.md의 첫 결정). ProcessGPT가 계속 유일한 오케스트레이터이고,
> WMS가 제공하는 것은 세 가지뿐이다: 관찰할 신호, 자율 실행과 사람 승인을
> 가르는 선, 그리고 "무엇을 보고 왜 그렇게 판단했는가"의 기록.
>
> 그래서 이 계약이 새로 만드는 쓰기 RPC 4종은 **어느 것도 WMS 원장이나 다른
> 도메인 상태를 건드리지 않는다.** 전부 `wms.agent_decisions` 한 테이블만
> 쓴다. 특히 `confirm_agent_proposal`은 상태 플래그를 바꿀 뿐,
> `proposed_action`에 적힌 RPC를 찾아 호출하지 **않는다**(design.md D7) —
> 그런 동적 디스패처는 그 자체로 Postgres 안의 자율 실행 루프이고, 이 계약이
> 피하려는 두 번째 오케스트레이션 엔진을 되살리는 일이다. 승인 뒤 실제 조치는
> 사람이 화면에서 하거나 다음 BPMN 스텝이 기존 RPC를 명시적으로 호출한다
> (`wms_submit_purchase_approval`과 같은 패턴).
>
> 세 에이전트 역할의 매핑은 이렇게 갈린다:
> **Wave Coordinator** — `get_dispatch_delay_signals`로 관찰하고, 이미 허용된
> `retry_work_order_dispatch`는 **직접** 호출하되 `log_agent_decision`으로 근거를
> 남긴다. 설비 강제 제외·라우팅 정책 변경은 계속 막혀 있으므로
> `propose_agent_action(EQUIPMENT_ROUTING_SUGGESTION)`으로 제안만 만든다.
> **Labor** — `get_labor_balance_signals`로 관찰하지만, 재배치 실행 RPC가 이
> 저장소에 **존재하지 않으므로** 모든 조치가 `LABOR_REBALANCE` 제안뿐이다.
> **Associate** — 새 계약이 거의 필요 없다. 모든 쓰기 RPC가 이미
> `next_actions`를 돌려주고 있어서, `get_worker_next_actions` 하나만 더했다.
>
> `get_labor_balance_signals`에는 의도적인 예외가 하나 있다.
> `get_labor_productivity`는 비관리자에게 `scope='SELF'`로 본인 행만 주는데,
> 인력 불균형은 본질적으로 여러 작업자를 비교하는 질문이라 그 규칙을 그대로
> 적용하면 에이전트가 자기 행 하나를 보게 되고 신호가 무의미해진다. 따라서 이
> 신호 **하나에 한해** PROCESS_AGENT에게 창고 전체 비교를 연다(design.md D2).
> 예외는 좁다 — 원본 활동 행(RLS 그대로), 리더보드(`scope='SELF'` 그대로),
> 그리고 재배치를 실행할 권한(애초에 없음)은 전혀 넓어지지 않는다. **볼 수
> 있는 것과 할 수 있는 것을 분리했으므로, 조회권 확장이 곧 통제력 확장이
> 아니다.**
>
> 감사 쪽에서는 `correlation_id`가 접착제다. 에이전트가
> `retry_work_order_dispatch`를 부를 때 쓴 것과 같은 값을
> `log_agent_decision`에 넘기면, `wms.audit_events`(무엇을 했는가)와
> `wms.agent_decisions`(왜 했는가)가 그 컬럼으로 이어진다 —
> `wms_operations-audit-log`가 소비하기로 확정한 조인이 정확히 이것이다.
> 재현 결과는 `openspec/specs/wms_agentic-operations/e2e/README.md` 참고.

> **note (자연어 감사 로그)**: 신규 도구 2종(`query_audit_log`,
> `export_audit_log`) 중 허용 목록에 들어가는 것은 **0종**이다. 열한 개 영역을
> 통틀어 신규 도구 전부가 제외된 유일한 계약이며, 그것이 이 계약의 요지다.
>
> 다른 모든 읽기 도구는 "에이전트가 다음에 무엇을 할지 정하기 위해" 존재한다.
> 이 둘은 반대 방향이다 — **에이전트가 이미 한 일을 사람이 확인하기 위해**
> 존재하고, 조회 결과에는 에이전트 자신의 판단 근거(`wms.agent_decisions.reasoning`)가
> 같은 `correlation_id`로 조인되어 함께 나온다. 감시 대상에게 감시 기록의
> 열람권을 주면 그 기록은 통제 수단이 아니게 된다.
>
> 그래서 이 둘은 이 파일에서 유일하게 **세 번째 서비스 아이덴티티**로 로그인한다
> (`WMS_AUDITOR_EMAIL`, `.env.example` 참고). RPC가
> `wms.has_role(tenant_id, 'WMS_ADMIN', 'AUDITOR')`를 검사하므로 PROCESS_AGENT
> 자격증명으로는 `FORBIDDEN`밖에 받을 수 없다 — 허용 목록에서 빼는 것이 예의고,
> 실제 통제는 DB에 있다(`verify.sql` §F가 PROCESS_AGENT를 포함한 4개 역할로
> 두 RPC를 직접 찔러 확인한다).
>
> `AUDITOR` 역할은 새로 만든 것이 아니다. 최초 마이그레이션
> (`20260726_wms_core_schema.sql` 30행)의 역할 주석에 처음부터 적혀 있었지만
> 어떤 RPC도 검사하지 않던 값이고, 이 계약이 그 부채를 갚는 첫 사용처다. 이
> 역할에는 저장소 어디에도 쓰기 권한이 없다 — 기록을 고칠 수 있는 감사자는
> 감사자가 아니다.
>
> 내보내기(`export_audit_log`)는 성공할 때마다 그 호출 자체를
> `wms.audit_events`에 남긴다(`command='wms_export_audit_log'`,
> `entity_type='audit_export'`). "누가 지난달 감사 로그를 통째로 내려받았는가"도
> 감사 대상이라는 뜻이다. 재현 결과는
> `openspec/specs/wms_operations-audit-log/e2e/README.md` 참고.

## 10.4/10.5: completion 연동

- **10.4** (`completion_automated-task-execution`): serviceTask의 `tool`을
  `mcp:<tool_name>`으로 지정하면 completion이 해당 도구만 에이전트에 노출한다.
  WMS의 `{result: "ok", document_id, status, version, next_actions}` envelope도
  기존 `{status: "success"}` 형식과 함께 workitem `output`에 보존한다.
- **10.5** (`completion_process-workitem-submission`): 구매 승인 human task는
  `wms_submit_purchase_approval`을 **frontend에서 로그인한 실제 사용자**가
  호출해야 한다(PROCESS_AGENT 역할은 이 RPC를 호출할 권한이 없음, 의도적).
  workitem 제출 시 `po_id`와 `expected_version`을 폼 hidden field로 보존해
  버전 충돌을 감지한다. 데모 프로세스의 승인 폼과 품질 폼에 이 필드가 포함된다.

## 설치

WMS MCP를 호스트의 `8199` 포트에 실행하고 ProcessGPT 로컬 스택이 준비된 상태에서:

```bash
cd services/sample-app-wms
python3 scripts/install_processgpt_integration.py
```

설치되는 실행 흐름:

```text
재고 부족 감지
→ get_availability
→ create_rfq
→ request_approval
→ 발주 승인(HITL)
→ confirm_po
→ register_arrival
→ receive
→ 품질검사(HITL)
→ putaway 또는 폐기 확인
```

설치 스크립트는 기존 `tenants.mcp` 항목을 보존한 채 `wms`만 병합하며, 기존
프로세스 인스턴스나 WMS 거래 데이터를 삭제하지 않는다.

## 로컬 검증 기록

`mcp/main.py`를 기동한 상태에서 fastmcp `Client`로 `get_availability` →
`create_rfq` → `request_approval` 3개 도구를 순서대로 호출해 실제 Postgres
왕복(가용재고 조회 → RFQ 생성 → 사람 승인 필요 여부 반환)을 확인했다. 전체
9개 RPC는 psql로 직접 호출해 happy path, 교차 테넌트 RLS 차단, 잘못된 역할
FORBIDDEN, 낙관적 동시성 CONFLICT, 멱등성(동일 키 재호출 시 중복 생성 없음)을
모두 확인했다.

WCS 설비 제어 계약(`wms_wcs-equipment-control`)의 신규 8개 RPC와 8개 MCP 도구도
같은 방식으로 검증했다 — psql 시뮬레이터와 fastmcp `Client` 왕복 스크립트, 그리고
그 실행 결과가 `openspec/specs/wms_wcs-equipment-control/e2e/`에 있다.

WES 자재 흐름 제어 계약(`wms_wes-material-flow-control`)의 신규 6개 RPC와 6개 MCP
도구도 같은 방식으로 검증했다 — psql 시뮬레이터, fastmcp `Client` 왕복 스크립트,
그리고 `/wes/dispatch` 화면을 실제로 조작하는 Playwright E2E(설비 쪽 피드백만
off-UI `psql`)의 실행 결과가 `openspec/specs/wms_wes-material-flow-control/e2e/`에
있다. 특히 "설비 명령 완료 보고 → 업무 오더 자동 COMPLETED" 전파는 UI에서 아무
버튼도 누르지 않은 채 화면 상태가 바뀌는 것으로 확인했다.

고속 분류 제어 계약(`wms_wcs-sortation-logic`)의 신규 3개 RPC와 3개 MCP 도구도
같은 방식으로 검증했다 — psql 시뮬레이터, fastmcp `Client` 왕복 스크립트, 그리고
`/wcs/sortation` 화면을 실제로 조작하는 Playwright E2E(분류 결과 보고만 off-UI
`psql`)의 실행 결과가 `openspec/specs/wms_wcs-sortation-logic/e2e/`에 있다. 특히
"잼(JAM) 보고 → 설비 자동 FAULT 승격 + 미종결 명령 일괄 FAILED"는 아무도 장애를
신고하지 않은 상태에서 `/wcs/monitor`에 장애가 나타나는 것으로 확인했다.
그 과정에서 발견한 선행 계약과의 불일치 2건(디스패치 RPC의 하드코딩된
`command_type` 목록, 거부된 payload는 롤백 때문에 감사 기록을 남길 수 없음)은
같은 README에 근거와 함께 기록했다.

지능형 라우팅/병목 해소 계약(`wms_wcs-bottleneck-routing`)의 신규 5개 RPC와 5개 MCP
도구도 같은 방식으로 검증했다 — psql 시뮬레이터, fastmcp `Client` 왕복 스크립트,
그리고 `/wcs/routing`과 `/wes/dispatch`를 함께 조작하는 Playwright E2E(설비 장애
보고만 off-UI `psql`)의 실행 결과가
`openspec/specs/wms_wcs-bottleneck-routing/e2e/`에 있다. 이 계약은 관찰 가능한
새 동작이 "업무 오더가 다른 설비로 간다"뿐이라, 모든 검증이 병목 판정 화면과
**실제 배정 결과**를 짝지어 확인하도록 되어 있다. 그 과정에서 발견한 선행 계약과의
불일치 4건(area 2의 후보 선택이 인라인 쿼리 3개가 아니라 whole-row 헬퍼 1개였던 점,
`QUEUE_DEPTH_EXCEEDED`가 후보 선택에는 구조적으로 도달할 수 없는 점, `WCS_OPERATOR`의
권한 경계, 강제 제외가 진행 중 명령을 멈추지 않는 점)은 같은 README에 근거와 함께
기록했다.
