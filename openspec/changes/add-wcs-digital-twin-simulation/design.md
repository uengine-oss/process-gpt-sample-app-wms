## Context

`add-wcs-equipment-control-contract`(area1, capability `wms_wcs-equipment-control`,
아직 미구현)는 WMS가 자동화 설비를 등록·지시·모니터링하는 소프트웨어 계약을
정의했다. 그 설계는 처음부터 "이 계약을 실제로 채우는 쪽은 진짜 WCS/PLC
게이트웨이일 수도, 데모용 소프트웨어 시뮬레이터일 수도 있다"(area1 Context)고
명시했고, 시뮬레이터가 상태를 보고할 때 쓰는 서비스 아이덴티티로 `WCS_GATEWAY`
역할을 별도로 만들었다(area1 D5). 이후 area2~5는 각자의 확장 지점 표에서
반복해서 이 변경을 예견했다 — 예를 들어 area2: "`WCS_GATEWAY`로 인증하는
시뮬레이터가 `wms_wcs-equipment-control`의 결과 보고 RPC를 호출하면, 이 계약의
완료 전파 트리거가 자동으로 반응한다 — 이 계약을 수정할 필요가 없다." area3~5도
동일한 문장 패턴을 반복했다.

`docs/04-wms-wcs-market-feature-catalog.md`(§2.2, §4)의 Swisslog SynQ 세부
스펙("디지털 트윈 기반의 에뮬레이션 및 시뮬레이션 도구를 탑재하여 사전 검증이
가능", "가상 환경 시뮬레이션 기반 운영 최적화")은 이 영역을 실제 벤더가 (1)
설비 제어 로직 사전 검증(에뮬레이션)과 (2) 운영 중 what-if 최적화 두 축으로
쓴다는 것을 보여준다. 이 설계는 그 두 축을 각각 다루되, 무게를 다르게 둔다 —
(1)은 이 저장소가 실제로 채울 수 있는 실체가 있는 계약이고(이 저장소에 실제
하드웨어가 전혀 없으므로, area1~5가 정의한 계약을 실제로 왕복시키는 유일한
경로다), (2)는 "타이밍 모델을 재사용한 산술 추정"으로 명시적으로 축소한
얇은 계약이다.

### 정직한 전제 확인 (구현 상태와 의존성의 성격)

- **area1~5 전부 아직 구현되지 않았다.** `supabase/migrations/`에 해당
  마이그레이션 파일이 없다. 이 설계가 참조하는 `wms.equipment`,
  `wms.equipment_commands`, `wms.equipment_status_events`,
  `wms_dispatch_equipment_command`, `wms_report_command_result`,
  `WCS_GATEWAY` 역할은 전부 area1의 design.md에 있는 **검토용 후보**이며,
  실제 DB에는 존재하지 않는다.
- **이 변경의 실제 DB 의존성은 area1뿐이다.** 이 설계가 추가하는 4개 테이블과
  10개 RPC는 `wms.equipment`, `wms.equipment_commands`,
  `wms_dispatch_equipment_command`, `wms_report_command_result`, `WCS_GATEWAY`
  역할만 참조한다. area2의 `wms.work_orders`/`wms.dispatch_waves`, area3의
  `wms.sortation_profiles`, area4의 `wms.wcs_routing_policies`/뷰, area5의
  `wms.outbound_orders`/`wms.dispatch_sequences`에는 스키마 의존성이 없다 —
  area4가 area1에만 하드 의존하고 area2와는 "구현 통합 의존성"으로만 연결한
  것과 같은 원칙(아래 D8).
- **`wms_report_command_result`의 `p_detail` 구조는 area3(`DIVERT`/`SET_SPEED`
  결과 outcome)와 area5(`PALLETIZE`/`WRAP` 결과 outcome, `loaded_items`)가
  각각 다르게 정의했다.** 이 설계가 그 구조를 몰라도(즉 area3/5가 구현되어
  있지 않아도) 시뮬레이터가 최소한 `COMPLETED`/`FAILED`라는 일반 결과는
  항상 보고할 수 있어야 한다 — 그렇지 않으면 이 변경이 area3/5에 하드
  의존하게 된다. 그래서 이 설계는 명령 타입별 결과 payload를 "알려진 명령
  타입이면 그 도메인 어휘를 쓰고, 모르면 일반 어휘로 대체"하는 계층으로
  둔다(D5).
- **`wms.equipment_commands.status`가 지원하는 값 집합(`PENDING`,
  `ACKNOWLEDGED`, `IN_PROGRESS`, `COMPLETED`, `FAILED`, `REJECTED`,
  `CANCELLED`)은 area1이 이미 정의했다.** 이 변경은 새 상태를 추가하지
  않는다 — 시뮬레이터는 그 기존 상태 기계를 그대로 밟아 나갈 뿐이다.

이 저장소는 별도 마이크로서비스나 별도 데이터베이스를 만들지 않는다. 새
테이블/RPC는 기존과 동일한 `wms` 스키마, 동일한 Postgres 인스턴스, 동일한
RLS/RPC 봉투 관례를 그대로 확장한다.

## Goals / Non-Goals

**Goals:**

- `is_simulated=true`로 표시된 설비에 대해, 디스패치된 명령을 설비별로
  설정 가능한 타이밍(단계별 지연)과 실패/잼 주입 확률에 따라 현실적인 상태
  전이(`PENDING`→`ACKNOWLEDGED`→`IN_PROGRESS`→`COMPLETED`/`FAILED`)로
  자동 진행시키는 계약.
- 그 진행이 area1의 `wms_report_command_result`를 실제로 호출해 이루어지도록
  해서, area1~5가 정의한 검증 트리거·완료 전파·감사 이벤트가 시뮬레이션
  환경에서도 그대로 동작함을 보장하는 계약(카탈로그의 "사전 검증").
- 진행 상태를 데이터베이스에 저장해, 시뮬레이터 프로세스가 재시작되어도
  중복 보고나 유실 없이 이어서 진행할 수 있는 재시작 안전성.
- 명령 타입을 아는 만큼(현재는 area3의 `DIVERT`/`SET_SPEED`, area5의
  `PALLETIZE`/`WRAP`) 그 도메인 결과 어휘를 재사용하고, 모르는 명령
  타입에는 일반 결과 어휘로 대체하는 계약.
- 설비 구성 변경(예: 특정 설비 집합만 사용)이 예상 완료 소요시간에 미치는
  영향을 시뮬레이터의 타이밍 모델을 재사용해 추정하는, 범위를 명시적으로
  좁힌 what-if dry-run 계약.

**Non-Goals:**

- **3D 모션·물리 시뮬레이션(진짜 디지털 트윈).** 설비의 실제 이동 경로,
  가속/감속 곡선, 충돌 회피 같은 물리 엔진은 다루지 않는다 — 이 계약은
  상태 전이 타이밍만 흉내 낸다. 카탈로그가 시사하는 Swisslog SynQ 수준의
  "가상 환경 시뮬레이션"은 이 소프트웨어 데모의 범위를 한참 넘는다.
- **실제 PLC/필드버스 프로토콜.** area1이 이미 그은 경계와 동일하다 — 이
  시뮬레이터도 area1의 RPC 계약 위에서만 동작하지, 필드버스 신호를
  흉내 내지 않는다.
- **결정론적 재현(시드 고정 랜덤).** 실패/잼 주입은 매 실행마다 다른
  결과를 낼 수 있는 확률적 과정이다 — "이전과 똑같은 시뮬레이션을 다시
  재현"하는 기능은 다루지 않는다(D6 트레이드오프).
- **ML/최적화 기반 시나리오 자동 탐색.** "가능한 설비 조합 중 최적을
  찾아라" 같은 탐색 알고리즘은 다루지 않는다 — 시나리오는 항상 호출자가
  구체적으로 지정한 설비 집합/건수에 대해서만 추정한다.
- **큐잉 이론 기반 정밀 대기시간 모델.** 시나리오 프로젝션은 "병렬 처리
  가능한 설비 수만큼 나눠 처리한다"는 단순 산술 모델이다(D7) — 실제 대기
  행렬, 우선순위 역전, 재시도 재대기 같은 정교한 모델은 다루지 않는다.
- **area2~5의 스키마에 대한 하드 의존.** 이 계약은 area1만으로 독립
  동작해야 한다(위 "정직한 전제 확인", D8).
- **결과 보고의 실시간 사람 알림(푸시 알림, 대시보드 경고).** 이 계약은
  `wms.equipment_status_events`/`wms.audit_events`에 사실을 남길 뿐, 알림
  채널은 다루지 않는다.
- 프론트엔드 화면 구현.

## Decisions

### D1. 시뮬레이션 대상 여부는 설비 레지스트리의 새 플래그(`is_simulated`)로
표현하고, 별도 "가상 설비" 테이블을 만들지 않는다

"시뮬레이션 전용 설비 종류"를 새 테이블로 분리하는 대안도 검토했다. 그러나
그러면 area1의 `wms.equipment`가 "진짜"와 "가상" 두 갈래로 나뉘어, area2~5의
가용 설비 선택 로직이 두 테이블을 모두 조회해야 하는 복잡도가 생긴다.
대신 `wms.equipment`에 `is_simulated boolean not null default false` 컬럼
하나만 추가한다(area3/5가 `command_type` `CHECK` 제약을 확장한 것과 동일한
원칙 — area1의 원 마이그레이션 파일은 수정하지 않고, 이 변경의 새
마이그레이션에서 `alter table ... add column`). 이렇게 하면 "이 설비는
실제 하드웨어 없이 소프트웨어로만 응답한다"는 사실이 설비 레지스트리
자체의 속성이 되어, area1~5의 다른 어떤 쿼리도 이 계약의 존재를 몰라도
동일하게 동작한다 — 시뮬레이터는 그 설비의 관점에서 "명령에 응답하는
행위자"일 뿐이다.

### D2. 시뮬레이터는 외부 워커 프로세스로 구현하고, Postgres 스케줄 함수로
구현하지 않는다

이것이 이 설계의 핵심 아키텍처 결정이다. 두 가지 메커니즘을 비교했다:

**옵션 A(기각): Postgres 스케줄 함수.** `pg_cron` 같은 확장으로 주기적으로
`plpgsql` 함수를 실행해, 시간이 된 명령을 찾아 상태를 전이시킨다. 장점은
운영이 단순하다는 것(추가로 기동해야 할 프로세스가 없다, Postgres가
재시작돼도 스케줄이 유지된다). 그러나 결정적인 문제가 있다 — **`wms_report_command_result`
등 area1의 쓰기 RPC는 `WCS_GATEWAY` 역할을 `wms.has_role(tenant_id, ...)`로
검사하고, 그 함수는 `auth.uid()`(Supabase Auth 세션의 JWT `sub` 클레임)에
의존한다.** `pg_cron`이 스케줄하는 백그라운드 잡은 데이터베이스 역할(대개
`postgres` 슈퍼유저)로 실행될 뿐, Supabase Auth 세션을 갖지 않는다 —
`auth.uid()`는 그 컨텍스트에서 `null`이다. 이를 우회하려면
`set_config('request.jwt.claims', ...)`로 세션 클레임을 수동 위조해야 하는데,
이는 이 저장소가 지금까지 지켜온 "모든 쓰기는 `SECURITY DEFINER` RPC를
통해서만, 그리고 그 RPC는 실제 인증된 호출자의 역할을 검사한다"는 신뢰
경계를 우회하는 것이다 — 시뮬레이터가 "진짜 `WCS_GATEWAY`처럼 인증해
계약을 채운다"(area1 D5, area1 Context)는 원래 설계 의도와도 어긋난다.

**옵션 B(채택): 외부 워커 프로세스.** `mcp/wms_mcp/mcp_server.py`와 같은
성격의, 소스에서 직접 실행하는 로컬 Python 스크립트가 `WCS_GATEWAY` 역할을
가진 시드 계정으로 Supabase Auth에 로그인해 실제 세션을 얻고, 그 세션으로
이 변경의 RPC(`wms_get_due_simulation_actions`, `wms_advance_simulated_command`
등)를 호출한다. 이는 실제 PLC/WCS 게이트웨이가 붙는 방식과 동일한 신뢰
경계를 그대로 따른다 — "실제 하드웨어 유무와 무관하게 동일하게 동작해야
한다"(area1 Context)는 원칙을 어기지 않는다. 트레이드오프는 이 워커
프로세스를 데모/E2E 실행 시 별도로 기동해야 한다는 운영 부담이다(아래
Risks). 이 저장소는 별도 마이크로서비스를 만들지 않는다는 제약과 이 선택이
모순되지 않는다 — 이 스크립트는 새 서비스가 아니라 `mcp_server.py`처럼
소스 트리에서 직접 실행하는 하나의 로컬 프로세스이고, 상태는 전부 같은
Postgres 인스턴스의 `wms` 스키마에 산다(D3).

### D3. 명령별 진행 계획은 DB 테이블(`wms.simulation_command_schedules`)에
저장해, 워커 프로세스 자체를 사실상 무상태로 만든다

워커가 "다음에 무엇을 언제 보고할지"를 프로세스 메모리에만 들고 있으면,
워커가 재시작될 때 진행 중이던 명령의 계획(랜덤으로 굴린 지연 시간, 실패
여부)이 사라진다. 대신 워커가 새 `PENDING` 명령을 처음 발견하면
`wms_plan_simulated_command`를 호출해 전체 계획(각 단계의 목표 시각, 최종
결과)을 한 번에 굴려 `wms.simulation_command_schedules`에 저장하고, 이후
매 폴링 주기마다 그 테이블에서 "지금 실행할 시각이 된" 행만 조회해
(`wms_get_due_simulation_actions`) 실행한다(`wms_advance_simulated_command`).
이렇게 하면:

- 워커가 몇 개든(단일 프로세스 가정이지만 이 설계는 여러 워커 인스턴스를
  막지 않는다), 재시작되든 계획 자체는 DB에 남아 있어 재시작 안전하다.
- 계획이 사람이 조회 가능한 데이터라서(운영자가 `wms_get_simulation_schedule_status`로
  "이 명령이 언제 완료될 예정인지" 확인 가능), 시뮬레이션 진행이 블랙박스가
  아니다.
- `wms_plan_simulated_command`는 이미 계획이 있는 명령에 대해서는 기존 계획을
  그대로 반환한다(멱등) — 워커가 같은 명령을 두 번 발견해도 계획이 두 번
  세워지지 않는다.

### D4. 프로파일이 없는 설비에는 시스템 기본 타이밍을 적용한다

area4 D4가 "정책이 없는 설비 유형에는 시스템 기본 임계값을 쓴다"고 정의한
것과 동일한 패턴이다. 운영자가 `wms.simulation_profiles`를 등록하지 않은
`is_simulated=true` 설비도 시뮬레이션이 즉시 동작해야 한다 — 그렇지 않으면
"설비를 시뮬레이션 모드로 켰는데 아무 일도 일어나지 않는다"는 혼란스러운
상태가 생긴다. 시스템 기본값(예: `ack_delay_ms` 500~1500, `progress_delay_ms`
1000~3000, `completion_delay_ms` 2000~5000, `failure_rate` 0.05, `jam_rate`
0)을 코드(RPC 내부 상수)에 내장하고, 프로파일이 있으면 그 값으로 대체한다.

### D5. 결과 payload는 명령 타입을 아는 만큼 도메인 어휘를 재사용하고,
모르면 일반 어휘로 대체한다

`wms_report_command_result`의 `p_detail` 구조는 area3(`DIVERT`/`SET_SPEED`
결과: `outcome in ('SUCCESS','MISROUTE','JAM')`)와 area5(`PALLETIZE`/`WRAP`
결과: `outcome`, `loaded_items` 배열)가 각자 다르게 정의했다. 이 변경은
area3/5의 스키마에 의존하지 않으므로(위 "정직한 전제 확인"), 그 어휘를
하드코딩할 수 없다. 대신 계획 수립 시점(`wms_plan_simulated_command`)에
대상 명령의 `command_type`을 보고 다음 규칙으로 `planned_detail`을 구성한다:

- `command_type in ('DIVERT')`: area3 어휘로 `{"outcome": "SUCCESS"|"MISROUTE"|"JAM", "actual_chute": ...}`를
  구성한다. 실패 시 `jam_rate` 확률로 `JAM`, 나머지는 `MISROUTE`.
- `command_type in ('PALLETIZE')`: area5 어휘로
  `{"outcome": "SUCCESS"|"PARTIAL"|"OVERWEIGHT"|"OVERVOLUME"|"ABORTED", "loaded_items": [...]}`를
  구성한다. `payload.sequence_items`가 있으면 그 항목 수만큼
  `loaded_items`를 만들고, 실패 시 일부를 `SKIPPED`로 표시해 `PARTIAL`을
  재현한다.
- 그 외 모든 `command_type`(`MOVE`, `LOAD`, `UNLOAD`, `START`, `STOP`,
  `RESET`, `HOLD`, `RESUME`, `SET_SPEED`, `WRAP`, 그리고 이후 추가될 수
  있는 알려지지 않은 값): 일반 어휘 `{"outcome": "SUCCESS"|"FAILURE", "reason": ...}`를
  사용한다. area1의 "명령 결과 보고" 계약은 애초에 `detail`을 자유
  `jsonb`로 정의했으므로(area1 데이터 모델), 이 일반 어휘도 유효한
  `wms_report_command_result` 호출이다.

이 매핑 로직은 순수하게 `command_type` 문자열에 대한 분기이므로, area3/5의
실제 테이블(`wms.sortation_profiles` 등)을 전혀 조회하지 않는다 — 하드
의존이 생기지 않는다(D8).

### D6. 실패/잼 주입은 확률적이며, 결정론적 시드를 제공하지 않는다

각 명령의 최종 결과(`COMPLETED` vs `FAILED`, 그리고 `FAILED`라면
`MISROUTE` vs `JAM`)는 계획 수립 시점에 `wms.simulation_profiles.failure_rate`/`jam_rate`를
확률로 한 번만 굴려(Postgres `random()`) 결정하고, 계획에 고정한다(즉 같은
명령을 여러 번 다시 확인해도 결과가 바뀌지 않는다 — 계획 자체는
결정론적으로 저장되지만, 계획을 세우는 그 순간의 주사위는 매번 다르다).
"똑같은 조건으로 다시 실행하면 항상 같은 결과가 나온다"는 재현성은 제공하지
않는다 — 실제 벤더의 에뮬레이션 도구도 보통 몬테카를로 방식의 확률적
시뮬레이션을 쓰지, 완전 결정론적 리플레이를 기본으로 제공하지 않는다는
점에서 이 선택은 현실적이다. 재현 가능한 시나리오가 필요해지면 후속
변경이 `wms.simulation_profiles`에 시드 컬럼을 추가하는 확장을 고려할 수
있다 — 이번 변경은 하지 않는다.

### D7. 시나리오 프로젝션은 "병렬 처리 가능한 설비 수로 나눈다"는 단순
산술 모델이며, 실제 명령을 디스패치하지 않는다

`wms_run_simulation_scenario`는 순수 읽기+계산이다 — `wms_dispatch_equipment_command`를
전혀 호출하지 않는다(area1의 명령 이력에 어떤 부작용도 남기지 않는다).
계산 방식: 시나리오가 지정한 설비 집합(`N`대, 각 설비의 프로파일 또는
D4의 기본값)에 대해, 대상 작업 건수(`command_count`)를 `N`으로 나눈
반복 횟수(`ceil(command_count / N)`)만큼 "설비 1대가 명령 1건을 처리하는
평균 소요시간"(프로파일의 `ack_delay`+`progress_delay`+`completion_delay`
중간값 합)이 걸린다고 가정해 `projected_completion_at`을 추정한다. 이는
실제 대기 행렬(설비마다 처리 속도가 다르거나, 우선순위가 있거나, 일부
작업이 재시도되는 등)을 무시한 낙관적 근사치다 — Non-Goals에 이미 명시한
대로, 진짜 큐잉 이론 모델이 아니다. `wms.simulation_profiles.failure_rate`의
평균을 곱해 `projected_failure_count`도 함께 추정치로 제공해, "이 정도
비율은 실패할 것으로 예상된다"는 참고 정보를 준다.

### D8. 시나리오의 대상(웨이브/업무 오더)은 느슨한 참조로 두고, 실제 대상
건수는 호출자가 넘겨준다

"웨이브 X를 설비 집합 Y로 처리하면 어떻게 될까"라는 시나리오를 완전히
자동화하려면 area2의 `wms.dispatch_waves`/`wms.work_orders`를 조회해
그 웨이브의 큐잉된 업무 오더 수를 직접 세야 한다. 그러나 이 변경은
area2~5에 하드 스키마 의존성을 만들지 않기로 했다(위 "정직한 전제 확인",
area4의 최소 의존성 선례와 동일한 판단). 대신 `wms.simulation_scenarios`는
`linked_entity_type`/`linked_entity_id`(area1 D6과 동일한 느슨한 참조,
nullable — 예: `'dispatch_wave'` + wave id, 순수 참고용 라벨일 뿐 조인
대상 아님)와 `p_command_count`(호출자가 직접 넘기는 정수)를 함께 받는다.
area2~5가 모두 구현된 환경이라면 호출자(사람 또는 향후 오케스트레이션)가
`wms_get_work_order_status`(area2) 등으로 실제 큐잉 건수를 먼저 조회한 뒤
그 값을 `p_command_count`로 넘겨 "웨이브 X와 사실상 동일한" 시나리오를
구성할 수 있다 — 이는 이 계약이 자동으로 하는 일이 아니라, 이 계약을
소비하는 쪽의 책임이라는 점을 정직하게 남긴다(area2가 "업무 오더 완료를
상위 엔티티로 자동 전파하지 않는다"고 그은 경계와 같은 원칙).

### D9. 새 service role을 추가하지 않는다

시뮬레이터의 인증 아이덴티티는 area1이 이미 도입한 `WCS_GATEWAY`를 그대로
쓴다 — area1 D5가 예견한 그대로다. 프로파일 관리·시나리오 정의는 사람
운영 판단 영역이므로 기존 `WMS_ADMIN`/`WAREHOUSE_MANAGER`/`WCS_OPERATOR`/
`PROCESS_AGENT` 역할을 재사용한다. 권한 모델의 표면을 넓히지 않는다.

## 데이터 모델 (검토용 후보)

> 아래는 구현 검토를 위한 스키마 초안이다. 실제 DDL은 구현 단계에서
> `supabase/migrations/`에 새 마이그레이션 파일로 추가한다 — 기존
> `20260726_wms_core_schema.sql`과 area1의 마이그레이션은 수정하지 않으며,
> area1이 먼저 적용된 뒤에만 이 변경의 마이그레이션을 적용할 수 있다.

### `wms.equipment.is_simulated` — 컬럼 추가 (area1 소유 테이블)

```sql
alter table wms.equipment
  add column is_simulated boolean not null default false;
```

### `wms.simulation_profiles` — 설비별 시뮬레이션 타이밍/실패율 프로파일 (신규)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `equipment_id` | `uuid` | FK `wms.equipment`(area1), unique — `is_simulated=true`인 설비만 허용(RPC에서 검증) |
| `ack_delay_ms_min` / `ack_delay_ms_max` | `int` | `PENDING`→`ACKNOWLEDGED` 지연 범위(ms), `min <= max`, `>= 0` |
| `progress_delay_ms_min` / `progress_delay_ms_max` | `int` | `ACKNOWLEDGED`→`IN_PROGRESS` 지연 범위 |
| `completion_delay_ms_min` / `completion_delay_ms_max` | `int` | `IN_PROGRESS`→종결(`COMPLETED`/`FAILED`) 지연 범위 |
| `failure_rate` | `numeric` | `0~1`, 종결이 `FAILED`가 될 확률 |
| `jam_rate` | `numeric` | `0~1`, 기본값 `0` — `FAILED`인 `DIVERT` 명령 중 `JAM`(vs `MISROUTE`)이 될 조건부 확률(D5) |
| `status` | `text` | `ACTIVE \| INACTIVE` — `INACTIVE`면 D4의 시스템 기본값으로 대체 |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.simulation_command_schedules` — 명령별 진행 계획 (신규, D3)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `equipment_id` | `uuid` | FK `wms.equipment` |
| `command_id` | `uuid` | FK `wms.equipment_commands`(area1), unique — 명령당 활성 계획 1건 |
| `next_status` | `text` | `ACKNOWLEDGED \| IN_PROGRESS \| COMPLETED \| FAILED` — 다음에 보고할 상태 |
| `next_run_at` | `timestamptz` | 다음 단계를 실행할 목표 시각 |
| `planned_terminal_status` | `text` | `COMPLETED \| FAILED` — 계획 수립 시점에 확정된 최종 결과(D6) |
| `planned_detail` | `jsonb` | 종결 단계에서 `wms_report_command_result`에 실어 보낼 `detail`(D5) |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | 마지막 단계 실행 시각 |

종결 상태(`COMPLETED`/`FAILED`)가 보고되면 이 행은 삭제된다(더 이상
"진행 중인 계획"이 아니므로) — 이력은 area1의 `wms.equipment_status_events`에
이미 남는다(D1 원칙과 동일: 사실의 사본을 두 곳에 두지 않는다).

### `wms.simulation_scenarios` — what-if 시나리오 정의 (신규)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `name` | `text` | 사람이 읽는 시나리오 이름 |
| `scenario_type` | `text` | `EQUIPMENT_SUBSTITUTION`(현재 유일한 값, 열린 집합 — area1 D7과 동일 패턴) |
| `linked_entity_type` | `text` | nullable, 예: `'dispatch_wave'`, `'work_order'` — 순수 참고 라벨(D8), 조인 대상 아님 |
| `linked_entity_id` | `uuid` | nullable |
| `equipment_ids` | `uuid[]` | 시나리오가 가정하는 설비 집합(area1 `wms.equipment` 참조, 배열 — 교차 테이블 FK 제약은 DB에서 강제하지 않고 RPC에서 개별 검증) |
| `command_count` | `int` | `> 0` — 이 설비 집합이 처리할 것으로 가정하는 명령 건수(D8) |
| `status` | `text` | `DRAFT \| RUN` |
| `version` | `int` | 낙관적 동시성 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |
| `updated_at` / `updated_by` | | |

### `wms.simulation_scenario_runs` — 시나리오 실행 결과 (신규)

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` | `uuid` | PK |
| `tenant_id` / `warehouse_id` | `uuid` | |
| `scenario_id` | `uuid` | FK `wms.simulation_scenarios` |
| `projected_completion_at` | `timestamptz` | D7의 산술 추정 결과 |
| `projected_round_count` | `int` | `ceil(command_count / 설비 수)`(D7) |
| `projected_failure_count` | `int` | 평균 `failure_rate` 기반 추정(D7) |
| `assumptions` | `jsonb` | 계산에 쓰인 설비별 프로파일 또는 기본값 스냅샷(추적성) |
| `warnings` | `text[]` | 예: 프로파일이 없어 기본값을 쓴 설비가 있을 때 |
| `correlation_id` | `text` | |
| `created_at` / `created_by` | | |

## 함수 계약 — 명령 진행 (검토용, RPC)

모든 RPC는 기존과 동일하게 `language plpgsql security definer set search_path =
wms, public`으로 정의하고, `CONFLICT:`/`FORBIDDEN:`/`INVALID:` 접두 예외와
`wms.idempotency_records` 캐시 조회(쓰기 RPC only)를 따른다. 명령 결과 보고
자체는 새 RPC를 만들지 않고 area1의 `wms_report_command_result`를 그대로
내부에서 호출한다(area2/3/5 선례).

| RPC | 주요 파라미터 | 허용 역할 | 비고 |
|---|---|---|---|
| `wms_set_equipment_simulation_mode` | `p_equipment_id, p_is_simulated, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` | `expected_version`은 설비 버전(area1과 동일 컬럼) |
| `wms_register_simulation_profile` | `p_equipment_id, p_ack_delay_ms_min, p_ack_delay_ms_max, p_progress_delay_ms_min, p_progress_delay_ms_max, p_completion_delay_ms_min, p_completion_delay_ms_max, p_failure_rate, p_jam_rate default 0, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` | 대상 설비가 `is_simulated=true`가 아니면 `INVALID:`. 이미 프로파일이 있으면 `INVALID:` |
| `wms_update_simulation_profile` | `p_profile_id, ...(위와 동일 필드들, 각각 default null), p_status, p_actor_id, p_idempotency_key, p_expected_version, p_correlation_id default null` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `WCS_OPERATOR` | `expected_version`은 프로파일 버전 |
| `wms_get_simulation_profile` | `p_tenant_id, p_warehouse_id, p_equipment_id default null` | 모든 테넌트/창고 멤버(읽기) | 설비 + 프로파일(없으면 D4 기본값 표시)을 조인한 조회 전용 함수 |
| `wms_plan_simulated_command` | `p_command_id, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WCS_GATEWAY` | 이미 계획이 있으면 기존 계획 반환(멱등, D3). 대상 명령의 설비가 `is_simulated=true`가 아니면 `INVALID:` |
| `wms_get_due_simulation_actions` | `p_tenant_id, p_warehouse_id, p_as_of default now()` | `WCS_GATEWAY` | `next_run_at <= p_as_of`인 계획을 `next_run_at` 오름차순으로 반환(워커의 폴링 쿼리) |
| `wms_advance_simulated_command` | `p_command_id, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WCS_GATEWAY` | 계획이 없거나 아직 `next_run_at`이 도래하지 않았으면 `INVALID:`. 내부적으로 `wms_report_command_result` 호출 후 계획을 다음 단계로 갱신하거나(종결 아니면) 삭제(종결이면) |
| `wms_get_simulation_schedule_status` | `p_tenant_id, p_warehouse_id, p_equipment_id default null, p_due_only default false` | 모든 테넌트/창고 멤버(읽기) | `p_due_only=true`면 `wms_get_due_simulation_actions`와 동일 필터, 아니면 전체 진행 중 계획 조회(모니터링용) |
| `wms_create_simulation_scenario` | `p_tenant_id, p_warehouse_id, p_name, p_scenario_type default 'EQUIPMENT_SUBSTITUTION', p_equipment_ids, p_command_count, p_linked_entity_type default null, p_linked_entity_id default null, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `PROCESS_AGENT`, `WMS_ADMIN` | `equipment_ids`가 비어 있거나 대상 설비가 존재하지 않으면 `INVALID:` |
| `wms_run_simulation_scenario` | `p_scenario_id, p_actor_id, p_idempotency_key, p_correlation_id default null` | `WAREHOUSE_MANAGER`, `PROCESS_AGENT`, `WMS_ADMIN` | 실제 명령 디스패치 없음(D7). 매번 새 `wms.simulation_scenario_runs` 행 생성(같은 시나리오를 여러 번 실행 가능) |
| `wms_get_simulation_scenario_status` | `p_tenant_id, p_warehouse_id, p_scenario_id default null` | 모든 테넌트/창고 멤버(읽기) | 시나리오 + 실행 이력을 조인한 조회 전용 함수 |

모든 쓰기 RPC는 성공 시 `{result: 'ok', document_id, status, version,
next_actions, warnings?}` 형태를 반환하고, `wms.audit_events`에
`entity_type in ('simulation_profile', 'simulation_command_schedule',
'simulation_scenario', 'simulation_scenario_run')` 레코드를 남긴다.
`wms_set_equipment_simulation_mode`는 `entity_type='equipment'`로 남긴다
(area1이 소유한 엔티티의 속성 변경이므로).

## 외부 워커 프로세스 (구현 검토용, 비-RPC)

`WCS_GATEWAY` 역할의 시드 계정으로 Supabase Auth 세션을 얻어 다음 루프를
반복하는 로컬 Python 스크립트(후보 위치: `mcp/wms_mcp/simulator/wcs_gateway_simulator.py`,
`mcp_server.py`와 같은 소스 실행 관례를 따른다):

1. 새로 `PENDING`이 된, `is_simulated=true` 설비의 명령을 찾는다(area1의
   `wms_get_equipment_status` 또는 이 계약의 읽기 RPC로 조회) — 계획이
   없는 것만.
2. 각 명령에 대해 `wms_plan_simulated_command`를 호출한다(D3, 멱등).
3. `wms_get_due_simulation_actions`를 폴링해(고정 주기, 예: 1~2초) 실행할
   때가 된 계획을 가져온다.
4. 각 계획에 대해 `wms_advance_simulated_command`를 호출한다 — 이 호출이
   내부적으로 `wms_report_command_result`를 실행해 area1~5의 트리거/전파를
   실제로 발동시킨다.
5. 오류(네트워크 단절, 세션 만료)는 재시도하고, 계획 자체는 DB에 남아
   있으므로(D3) 워커가 몇 초 멈춰도 계획이 유실되지 않는다.

이 워커는 `mcp/wms_mcp/mcp_server.py`가 이미 이 저장소에서 확립한 "소스에서
직접 실행하는 로컬 프로세스" 관례를 그대로 따르며, `authenticated`
권한 부여 대상이 아니라 실제 로그인 세션을 쓰는 일반 클라이언트로 동작한다
— 새 인증 메커니즘을 도입하지 않는다.

## 역할 모델

새 역할을 추가하지 않는다(D9). 기존 역할 재사용:

| 역할 | 이 계약에서의 권한 |
|---|---|
| `WMS_ADMIN` | 모든 쓰기 RPC 호출 가능 |
| `WAREHOUSE_MANAGER` | 시뮬레이션 모드 지정, 프로파일 관리, 시나리오 정의·실행 |
| `WCS_OPERATOR` | 프로파일 관리(시뮬레이션 모드 지정은 불가 — 설비를 시뮬레이션 대상으로 켜고 끄는 것은 운영 관리자 권한으로 제한) |
| `PROCESS_AGENT` | 시나리오 정의·실행(ProcessGPT 자동화 경로) |
| `WCS_GATEWAY` | 명령 계획 수립, 대기 액션 조회, 명령 진행 보고 — 이 계약의 실제 실행 주체(area1 D5와 동일 원칙). 프로파일 관리·시나리오 정의 권한 없음 |
| (모든 멤버) | 프로파일/스케줄/시나리오 상태 읽기 |

## RLS 패턴

기존 테이블과 동일하게, 신규 4개 테이블 모두:

- `enable row level security`.
- `select` 정책: `warehouse_id in (select wms.current_warehouse_ids(tenant_id))`.
- `insert`/`update`/`delete` 정책 없음 — 모든 쓰기는 위 `security definer` RPC를
  통해서만 이루어진다.

`wms.equipment`(area1)의 기존 RLS 정책은 변경하지 않는다 — `is_simulated`
컬럼 추가는 정책이 적용되는 행 집합에 영향을 주지 않는다.

## 확장 지점

이 변경은 WCS/WES 계열 스펙 시리즈(area1~6)의 마지막 항목이다. 시리즈
내부의 후속 확장 지점은 없다. 이 계약 자체의 향후 확장 후보는 다음과 같다
(이번 변경에 포함하지 않음):

- **실제 하드웨어 게이트웨이로의 교체.** 이 워커 프로세스와 동일한 RPC
  계약(`wms_dispatch_equipment_command` 소비, `wms_report_command_result`
  호출)을 실제 PLC/WCS 게이트웨이가 채우면, `is_simulated=false`로 전환하는
  것만으로 시뮬레이션에서 실제 운영으로 전환할 수 있다 — 이는 area1이
  애초에 의도한 대체 가능성이다.
- **시나리오와 area2~5의 실시간 데이터 통합.** D8이 정직하게 남긴 공백
  (`p_command_count`를 호출자가 직접 넘겨야 하는 것)을 자동화하는 후속
  통합.
- **결정론적 재현(D6 트레이드오프의 해소).**

## 프론트엔드 확장 지점 (구현 아님, 위치만 기록)

- `/wcs/simulation` — 설비별 시뮬레이션 모드 전환, 프로파일 등록/조회,
  진행 중인 계획 현황을 보여주는 화면 후보. `frontend/src/views/`에
  `SimulationView.vue` 형태로 추가될 후보. area1의 `/wcs/monitor`와 함께
  배치될 수 있다.
- `/wcs/scenario-planner` — 시나리오 정의·실행·결과(예상 완료 시점, 실패
  추정치) 비교 화면 후보.

이번 변경은 위 두 화면을 구현하지 않는다 — RPC/MCP 계약과 워커 프로세스만
제공한다.

## Risks / Trade-offs

- **선행 변경(area1) 미구현에 대한 의존.** 완화책: 이 변경의 실제 마이그레이션
  의존성은 area1뿐임을 명시했고(Context), tasks.md에 마이그레이션 적용
  순서를 명시한다.
- **외부 워커 프로세스는 데모/E2E 실행 시 별도로 기동해야 하는 네 번째
  프로세스가 된다(frontend, mcp 서버, Supabase에 더해).** 완화책: 이는
  D2에서 정당화한 필연적 트레이드오프다(auth.uid() 세션 요구사항) —
  tasks.md에 실행 스크립트/문서를 명확히 남기고, 워커가 죽어도 area1~5의
  나머지 계약(수동 명령 디스패치·결과 보고, 사람 운영자가 직접 `WCS_OPERATOR`로
  개입)은 독립적으로 여전히 동작함을 명시한다 — 워커는 단일 실패 지점이
  아니라 "선택적으로 붙는 자동 응답자"일 뿐이다.
- **확률적 실패 주입이 재현 불가능하다(D6).** 완화책: 이는 정직하게
  Non-Goal로 남겼다 — 필요해지면 시드 컬럼 추가로 확장 가능한 경로를
  design.md에 남긴다.
- **시나리오 프로젝션이 단순 산술 근사이며 실제 신뢰도가 검증되지
  않았다(D7).** 완화책: RPC 응답과 spec.md 시나리오 양쪽에 "이것은 낙관적
  추정치이지 보장이 아니다"를 명시하고, `warnings` 필드로 기본값을 쓴
  설비가 있는지 항상 알려준다.
- **시나리오의 대상 참조가 느슨하고(D8) 실제 대상 건수를 호출자가 수동으로
  넘겨야 한다.** 완화책: 이는 area2~5에 대한 하드 의존을 피하기 위한
  의도적 경계다 — 이 공백을 감추지 않고 tasks.md와 §5 카탈로그 갱신에
  "미해결 통합 지점"으로 명시한다.
- **`wms.simulation_command_schedules`가 워커의 폴링 주기보다 세밀한
  타이밍을 요구하면(예: 지연이 폴링 주기보다 짧으면) 실제 보고 시각이
  계획보다 늦어질 수 있다.** 완화책: 시스템 기본 지연(D4)이 폴링 주기(수
  초)보다 충분히 길게 설정되어 있어 이 샘플 앱 규모에서는 체감 오차가
  작다 — 정밀한 실시간 타이밍 보장은 애초에 이 계약의 목표가 아니다(Non-Goals).
