# `wms_yard-dock-scheduling` — 검증 기록

이 폴더는 야드/도크 스케줄링 계약
(`openspec/changes/add-yard-dock-scheduling`)의 구현을 실제로 돌려 본 기록이다.
스크린샷은 전부 통과한 Playwright 실행에서 나온 실제 프레임이며, SQL 출력은
로컬 Supabase(`supabase_db_process-gpt-sample-app-wms`)에서 그대로 복사한 것이다.

## 구성

| 파일 | 내용 |
|---|---|
| `verify.sql` | 8개 RPC 전부와 spec.md의 모든 시나리오를 psql로 왕복 검증. 자체 픽스처(`DOCK-V-*`)를 만들고 지운다 — db reset 없이 반복 실행 가능 |
| `verify-run.txt` | 위 스크립트의 실제 출력 |
| `double_booking_concurrent.sh` | 두 커넥션에서 겹치는 시간창을 동시에 예약해 보는 경쟁 조건 재현 |
| `double-booking-run.txt` | 위 스크립트의 실제 출력 |
| `playwright-run.txt` | 이 영역 스펙 단독 실행 + 전체 15개 테스트 실행 결과 |
| `screenshots/` | `frontend/playwright/e2e/dock-schedule-flow.spec.ts`가 남긴 14장. DOCX 매뉴얼의 재료 |

## 실행 방법

```bash
# 1) psql 검증 (자체 픽스처, 반복 실행 가능)
cd openspec/specs/wms_yard-dock-scheduling/e2e
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -f - < verify.sql

# 2) 동시 이중 예약 재현
./double_booking_concurrent.sh

# 3) UI E2E (스크린샷 재생성 포함)
cd ../../../../frontend
npx playwright test dock-schedule-flow --reporter=list
```

## 무엇이 확인되었나

### A. 도크 레지스트리

- 등록 직후 상태는 `AVAILABLE`, `version=1`.
- 같은 창고에서 `code` 중복 → `INVALID`.
- `INBOUND_OPERATOR`가 등록 시도 → `FORBIDDEN` (레지스트리는
  `WMS_ADMIN`/`WAREHOUSE_MANAGER`만).
- 테넌트 A 관리자가 테넌트 B 창고에 등록 시도 → `FORBIDDEN`.

### B. 예약 생성 가드

역방향 시간창, `po_id` 없는 `INBOUND`, 다른 창고의 PO, `CLOSED` 도크 —
전부 `INVALID`. 그리고 `OUTBOUND` 예약이 실제로 동작한다(아래 "설계와 달라진 점").

### C. 이중 예약 방지 (design.md D1) — 이 계약의 핵심

네 가지를 서로 다른 층위에서 확인했다.

1. **RPC 레벨**: `DOCK-V-01` 09:00–10:00이 있는 상태에서 09:30–10:30 요청 →
   `CONFLICT: dock DOCK-V-01 already has an active appointment overlapping ...`
2. **반열림 구간**: 같은 도크의 10:00–11:00은 겹치지 않으므로 성공. 시간창을
   `tstzrange(start, end, '[)')`로 잡은 결과가 그대로 관찰된다.
3. **스토리지 엔진 레벨**: RPC를 완전히 우회해 superuser로 테이블에 직접
   `INSERT`해도 거부된다 —
   `conflicting key value violates exclusion constraint "dock_appointments_no_double_booking"`.
   즉 이중 예약 방지는 애플리케이션 규칙이 아니라 스키마 불변식이다.
4. **동시성(경쟁 조건)**: `double_booking_concurrent.sh`가 실제 phantom-row
   race를 재현한다. S1이 커밋하지 않은 채 09:00–10:00을 잡고 있는 동안 S2가
   09:30–10:30을 시도하면 **S2는 블록된다**(S1이 커밋할지 롤백할지 아직
   모르므로). S1이 커밋하는 순간 S2가 깨어나 `CONFLICT`로 실패한다:

   ```text
   [S1] 58.917s  attempting insert
   [S1] SCHEDULED
   [S1] 58.929s  insert returned
   [S2] 59.922s  attempting insert          <- 여기서 멈춘다
   [S1] 01.939s  committed
   [S2] ERROR:  CONFLICT: dock DOCK-C-01 already has an active appointment overlapping [...]
   [S2] 01.940s  committed
   ```

   `SERIALIZABLE`도 advisory lock도 쓰지 않았고, 기본 `READ COMMITTED`에서
   그대로 성립한다. design.md D1이 "애플리케이션 레벨 체크로는 막을 수 없다"고
   기각한 대안과의 차이가 바로 이 블로킹이다.
5. **취소는 슬롯을 즉시 되돌려준다**: exclusion 제약의 `WHERE` 절이
   `SCHEDULED/CHECKED_IN/AT_DOCK`만 덮으므로, 예약을 `CANCELLED`로 바꾼 직후
   같은 시간창이 다시 예약된다. UI에서도 동일하게 재현된다
   (`10-appointment-cancelled.png` → `11-slot-rebooked.png`).

### D. 차량 생애주기와 파생 도크 상태 (design.md D4)

| 단계 | 예약 상태 | 도크 상태 |
|---|---|---|
| 예약 | `SCHEDULED` | 그대로 |
| 야드 체크인 | `CHECKED_IN` | **그대로 `AVAILABLE`** — 야드에는 들어왔지만 접안 전 |
| 도킹 | `AT_DOCK` | `OCCUPIED` |
| 출차 | `DEPARTED` | `AVAILABLE` |

거부되는 것들: 점유 중 도크를 `CLOSED`로 전환, 이미 점유된 도크에 두 번째
도킹, 도킹 전 출차, `AT_DOCK`에서 재체크인, `AT_DOCK` 예약 취소 — 전부
`INVALID`. `expected_version` 불일치는 `CONFLICT`.

`wms_set_dock_status`에 `OCCUPIED`를 직접 넘기는 것도 `INVALID`다 — 점유는
파생 상태이지 명령 대상이 아니다.

### E. 역할 경계 (design.md D5)

`PROCESS_AGENT`로 실행했을 때:

| RPC | 결과 |
|---|---|
| `wms_schedule_dock_appointment` | ✅ `SCHEDULED` |
| `wms_cancel_dock_appointment` | ✅ `CANCELLED` |
| `wms_get_dock_schedule` | ✅ |
| `wms_check_in_vehicle` | ❌ `FORBIDDEN` |
| `wms_dock_vehicle` | ❌ `FORBIDDEN` |
| `wms_depart_vehicle` | ❌ `FORBIDDEN` |
| `wms_register_dock` | ❌ `FORBIDDEN` |
| `wms_set_dock_status` | ❌ `FORBIDDEN` |

화면도 같은 경계를 그린다 — `WAREHOUSE_MANAGER`에게는 예약 폼과 차량 버튼이
아예 렌더되지 않고, `INBOUND_OPERATOR`에게는 도크 등록 폼이 렌더되지 않는다
(`12-manager-role-view.png`, `14-operator-role-view.png`).

### F. RLS / 교차 테넌트

psql은 superuser로 붙기 때문에 RLS를 **우회한다**. 그래서 `verify.sql`의 F4
구간은 `set local role authenticated`로 역할을 실제로 내려서 검사한다.

- 테넌트 B 관리자: 테넌트 A 도크 0건, 예약 0건.
- 테넌트 A 담당자: 같은 쿼리로 자기 도크는 보인다.
- `authenticated`로 테이블에 직접 `INSERT`/`UPDATE` → `permission denied for
  table docks`(`SELECT` 권한만 부여되어 있음).
- `information_schema.role_table_grants` 확인: 두 테이블 모두
  `authenticated`에 `SELECT`만, `anon`에는 아무것도 없음.
- RPC 레벨 가드도 별도로 동작한다 — 다른 테넌트 창고의 스케줄 조회/예약 생성은
  `FORBIDDEN`.

### G. 기존 입하 접수와의 독립성 (design.md D2)

- 도크 예약이 **전혀 없는** PO → `wms_register_arrival`이 그대로 `ARRIVED`.
- 예약이 `SCHEDULED`에 머물러 있는 PO → 역시 `ARRIVED`. `AT_DOCK`을
  요구하지 않는다.
- `wms_register_arrival` 호출이 `dock`/`dock_appointment` 감사 이벤트를
  남기지 않고, 이 계약의 어떤 행도 건드리지 않는다.
- 반대 방향도 확인: 도크 쪽 RPC들이 `receipt` 감사 이벤트를 남기지 않는다
  (Playwright 테스트 2의 마지막 단언).
- 마이그레이션 diff상 `wms_register_arrival`은 한 글자도 수정되지 않았다.

### H. 감사 추적 / 멱등성

- 쓰기 RPC 7종 모두 `wms.audit_events`에 기록된다. 상태 전이 RPC는
  `before`/`after`가 모두 채워지고(`wms_dock_vehicle` →
  `CHECKED_IN` / `AT_DOCK`), 생성 RPC는 `after`만 채워진다.
- `wms_dock_vehicle`과 `wms_depart_vehicle`은 **두 개**의 감사 이벤트를 남긴다
  (`dock_appointment` 하나 + `dock` 하나) — 도크 상태 변경도 감사 대상이기
  때문이다. 단, 출차 시 도크가 `CLOSED`라 해제하지 않은 경우에는 도크 쪽
  이벤트가 없다(바뀐 것이 없으므로).
- 같은 `idempotency_key`로 예약 생성을 두 번 호출하면 같은
  `appointment_id`가 반환되고 행은 1건만 생긴다 — 재시도가 exclusion 제약에
  걸려 `CONFLICT`로 뒤집히지 않는다(캐시된 응답이 먼저 반환되므로).

## 설계와 달라진 점 (정직한 기록)

### D3-AMENDED — `OUTBOUND` 예약을 연기하지 않고 구현했다

design.md D3은 "`add-wcs-sequential-dispatch`가 `wms.outbound_orders`를
제안했으나 아직 메인 스키마에 병합되지 않았다"는 전제 위에
`appointment_type='OUTBOUND'`를 **컬럼만 있는 확장 지점**으로 남겼다. 그 전제는
이제 사실이 아니다 — `supabase/migrations/20260731_wcs_sequential_dispatch.sql`이
실제로 `wms.outbound_orders`를 만들고, 이 마이그레이션(20260802)보다 먼저
적용된다. 죽은 메타데이터를 남기는 대신 동작하는 예약 타입으로 구현했다.

바뀌지 않은 것: **하드 FK는 여전히 없다.** area1의 `wms.equipment_commands`와
같은 느슨한 `(linked_entity_type, linked_entity_id)` 쌍을 그대로 쓴다. 추가된
로직은 RPC 안의 스코프 검사 하나뿐이다 — `linked_entity_type='outbound_order'`
일 때만 그 id가 같은 테넌트·창고의 `wms.outbound_orders`에 있는지 확인하고,
다른 `linked_entity_type` 값은 해석 없이 그대로 저장한다. 따라서 향후 다른
출고 모델이 들어와도 마이그레이션 없이 얹을 수 있다.

파생된 스키마 결정: `po_id`는 `INBOUND`에서 필수(spec.md)이고 `OUTBOUND`에서는
`NULL`이어야 한다(`dock_appointments_outbound_po_ck`). PO는 입고 문서이므로
출고 예약이 이를 들고 있으면 `po_id`의 의미가 무너진다.

### `btree_gist`는 이 저장소에서 처음 켜지는 extension이다

`supabase/` 아래 어디에도 `create extension`이 없었다(grep으로 확인). `EXCLUDE
USING gist (dock_id WITH =, ...)`에서 `uuid`의 `=` 연산자를 GiST 인덱스에서
쓰려면 `btree_gist`가 필요하므로 이 마이그레이션이 켠다.

### 프론트엔드는 design.md의 "확장 지점"이 아니라 이번 범위에 포함됐다

design.md "확장 지점" 절과 tasks.md §7은 `/inbound/dock-schedule` 화면을
후속 작업으로 미뤘지만, 이번 구현에는 포함했다. 경로는 그 절이 지정한
`/inbound/dock-schedule` 그대로다. 화면은 캘린더 위젯이 아니라 도크×시간
테이블이다 — 이 계약이 증명해야 하는 것은 "겹치는 예약이 불가능하다"이고,
그건 표로도 똑같이 보인다.

### 사이드바를 그룹으로 나눴다

화면이 13개가 되면서 평면 목록이 읽기 어려워져, `App.vue`의 내비게이션을
`WMS`(Overview/Replenishment/Purchase Orders/Receiving/**Dock Schedule**/Quality)와
`WCS / WES`(설비~시뮬레이션) 두 그룹으로 나눴다. 링크 경로와 라벨은 그대로라
기존 스펙/매뉴얼이 깨지지 않는다.

## 알려진 제약

- **테스트 하네스 주의**: psql에서 RPC 호출과 그 결과 조회를 **한 문장** 안에
  넣으면 하위 SELECT가 문장 이전 스냅샷을 읽어 옛 상태를 보고한다. 계약
  버그가 아니라 스냅샷 의미론이다 — `verify.sql`의 D2/D6/E 구간은 그래서
  문장을 나눴다(파일 안에 주석으로 남겨 뒀다).
- `wms-flow.spec.ts`가 시드된 재고 부족 상태에 의존해 `supabase db reset`
  없이 재실행하면 실패하는 기존 문제는 이 영역과 무관하며 그대로 남아 있다.
- 이 계약은 이산 상태 전이만 다룬다. "지금 야드 어느 좌표에 있는가"에는
  답하지 않는다(design.md Non-Goals).
