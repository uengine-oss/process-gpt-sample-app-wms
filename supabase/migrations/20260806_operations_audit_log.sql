-- ============================================================
-- Natural-language operations audit log contract
-- Scope: openspec/changes/add-operations-audit-log
--        (proposal.md / design.md / specs/wms_operations-audit-log/spec.md)
--
-- The ELEVENTH and last area, and the one that adds NO TABLE AT ALL.
--
-- Everything this contract reads was already being written. Every one of the
-- ten migrations before this file ends its write RPCs with the same four
-- lines:
--
--   insert into wms.audit_events
--     (tenant_id, actor_id, command, entity_type, entity_id, before, after,
--      correlation_id) values (...);
--
-- 65 distinct `command` values across 11 files, all of them structured JSONB.
-- The recording has never been the problem. What was missing is the two
-- things an auditor actually needs on top of it:
--
--   1. A PRESENTATION LAYER — a Korean sentence per event, so a finance or
--      audit reviewer can scan a page instead of reading `to_jsonb(row)`.
--   2. A PURPOSE-BUILT QUERY SURFACE — filter by period / actor / entity /
--      command / correlation id, paginate, export.
--
-- So this migration adds exactly three functions and nothing else:
--
--   wms.describe_audit_event(...)  — read-time, deterministic, IMMUTABLE
--   wms.wms_query_audit_log(...)   — filtered + paginated read
--   wms.wms_export_audit_log(...)  — filtered bulk read that audits itself
--
-- NO new table. NO column added to wms.audit_events. NO change to the
-- existing `audit_events_select` RLS policy (D2 — verified by diff; this file
-- contains no `alter policy`, no `drop policy`, no `alter table
-- wms.audit_events`). NO LLM call from inside Postgres (D1, and a Non-Goal
-- spelled out in design.md: an HTTP extension inside a write transaction buys
-- latency, an external dependency and an unpredictable bill for a sentence a
-- CASE can assemble).
--
-- ORDERING / DEPENDENCIES:
--   20260726_wms_core_schema.sql     — wms.audit_events, wms.memberships,
--                                      wms.has_role
--   20260805_agentic_operations.sql  — wms.agent_decisions (STAGE 2 only; see
--                                      V2 and the guard block below)
-- The other nine migrations are dependencies only in the sense that this file
-- writes a Korean template for each of their commands. None of them is
-- modified, and none of them has to be present for this file to install: an
-- unknown `command` falls through to the generic template (D1) rather than
-- erroring, which is the whole reason that fallback exists.
--
-- ------------------------------------------------------------
-- DEVIATIONS from design.md, deliberate and small:
--
-- V0. PARAMETER ORDER: NOTHING TO HOIST. Areas 7, 8 and 9 each had to move a
--     defaulted parameter above a required one because design.md's RPC table
--     listed them in an order PostgreSQL rejects. Both signatures here take
--     exactly one required parameter (`p_tenant_id`) and every filter after it
--     is optional, so the designed order is also a legal order. Implemented as
--     written.
--
-- V1. THE TWO RPCs TAKE THE SAME FILTERS IN THE SAME POSITIONS.
--     design.md's table omits `p_entity_id` from the export signature (query
--     has it). Rather than give the two surfaces different parameter orders —
--     which is a trap for anyone calling them positionally, and a trap for the
--     frontend that hands the same filter object to both — export takes the
--     identical eight filters in the identical order, and differs only in its
--     tail: query ends with (p_limit, p_offset), export with (p_max_rows).
--     Purely additive against design.md; every documented call form still
--     compiles.
--
-- V2. STAGES 1 AND 2 ARE MERGED, BECAUSE AREA 10 SHIPPED FIRST.
--     design.md D3 and tasks.md §2b split this contract in two: stage 1 with
--     no `wms.agent_decisions` join (so this area could land even if the
--     agentic contract never did), stage 2 adding the join afterwards with a
--     `create or replace` that leaves the signatures untouched.
--
--     tasks.md §2b.1 says to check `to_regclass('wms.agent_decisions')` first.
--     Checked — it is real, in 20260805_agentic_operations.sql line 246, with
--     `reasoning text not null` (line 263) and `correlation_id text` (275),
--     exactly the shape D3 assumed. The guard block below re-asserts that at
--     migration time rather than trusting this comment.
--
--     So both stages are implemented at once and each function is written
--     ONCE, with the join in place, instead of being defined and then
--     immediately replaced 150 lines later. The join is deliberately confined
--     to a single `left join lateral (...) ad on true` block in each function
--     and reaches nothing else: delete those two blocks, replace `ad.reasoning`
--     with `null::text`, and you have the stage-1 function back, with the same
--     signature and the same return shape. §"판단 근거 없는 이벤트" of the
--     verify suite exercises that degraded path for real (most events have no
--     matching decision), which is what stage 1 was there to protect.
--
-- V3. THE JOIN IS `LEFT JOIN LATERAL ... LIMIT 1`, NOT A PLAIN `LEFT JOIN`.
--     `wms.agent_decisions.correlation_id` is not unique — nothing in area 10
--     constrains it, and an agent that files a decision and then a proposal
--     under one ProcessGPT `process_instance_id` produces two rows for one id.
--     A plain LEFT JOIN would then emit the same audit event twice and inflate
--     `total_count` past what the paginator counted. The lateral picks the most
--     recent matching decision and returns at most one row. It is also scoped
--     by `d.tenant_id = e.tenant_id`: `correlation_id` is free text, and two
--     tenants can collide on one without either being wrong.
--
-- V4. THE EXPORT'S SELF-AUDIT ACTOR IS `auth.uid()`, NOT `p_actor_id`.
--     Every other write RPC in this repo takes the acting user as `p_actor_id`.
--     Here `p_actor_id` is already spoken for — it is the actor *filter*
--     ("show me what buyer-a did"). Reusing it for the self-audit row would
--     record "the auditor filtered by X" as "X exported the log", which is a
--     falsified audit record in the one function whose reason for existing is
--     to be un-falsifiable. The self-audit row therefore takes its actor from
--     `auth.uid()`, which the caller cannot choose.
--
-- V5. THE 10,000-ROW CAP IS A CEILING-BOUNDED PARAMETER, NOT A LITERAL.
--     design.md D5 fixes the export safety limit at 10,000 rows. As a bare
--     literal that branch is untestable without a 10,001-row fixture, and
--     tasks.md §3.4 resorts to "temporarily lower the constant, then put it
--     back" — i.e. verifying code that is not the code that ships. Instead
--     `p_max_rows` defaults to 10,000 and is itself validated against a hard
--     `WMS_AUDIT_EXPORT_MAX_ROWS = 10000` ceiling: callers may lower the safety
--     limit, never raise it. `p_max_rows => 20000` is INVALID. The shipped
--     branch is the tested branch.
--
-- V6. THE QUERY RPC ALSO RETURNS `facets`. design.md's response contract names
--     `summary_ko` and `total_count`. A filter UI needs one more thing: the
--     legal values. There are 65 command names spread over eleven migrations,
--     and the only alternatives to returning them were hard-coding that list
--     into AuditLogView.vue (where it rots the first time area 12 lands) or
--     deriving the dropdown from the current page (where narrowing the filter
--     deletes the options you need to widen it again). `facets` is computed
--     over the tenant's whole log, independent of the active filters, so the
--     dropdowns hold still while you use them. Purely additive.
-- ============================================================

-- tasks.md §2b.1, enforced rather than assumed.
do $$
begin
  if to_regclass('wms.agent_decisions') is null then
    raise exception
      'wms_operations-audit-log stage 2 requires wms.agent_decisions '
      '(supabase/migrations/20260805_agentic_operations.sql). Apply that first.';
  end if;
end $$;

-- ============================================================
-- Presentation helpers (D1).
--
-- Four tiny IMMUTABLE functions so the 66-branch CASE below reads as
-- sentences rather than as coalesce chains. All of them treat a missing key,
-- a NULL jsonb and an empty string identically — a summary must never be the
-- thing that breaks a page (spec.md: "before/after 일부 필드가 비어 있어도
-- 요약이 깨지지 않는다").
-- ============================================================

-- Raw lookup: after wins over before, NULL if neither has it.
create or replace function wms._audit_val(p_after jsonb, p_before jsonb, p_key text)
returns text
language sql immutable
as $$
  select coalesce(nullif(p_after ->> p_key, ''), nullif(p_before ->> p_key, ''));
$$;

-- Same, but always printable.
create or replace function wms._audit_txt(p_after jsonb, p_before jsonb, p_key text)
returns text
language sql immutable
as $$
  select coalesce(wms._audit_val(p_after, p_before, p_key), '—');
$$;

-- Optional clause: renders ", <label> <value>" only when there is a value, so
-- an absent `reason` leaves no ", 사유 —" litter in the sentence.
create or replace function wms._audit_opt(p_label text, p_value text)
returns text
language sql immutable
as $$
  select case
    when p_value is null or btrim(p_value) = '' then ''
    else format(', %s %s', p_label, btrim(p_value))
  end;
$$;

-- Transition: "A → B" when the value actually moved, otherwise just the value.
create or replace function wms._audit_chg(p_after jsonb, p_before jsonb, p_key text)
returns text
language sql immutable
as $$
  select case
    when p_before ->> p_key is not null
     and p_after  ->> p_key is not null
     and p_before ->> p_key is distinct from p_after ->> p_key
      then format('%s → %s', p_before ->> p_key, p_after ->> p_key)
    else wms._audit_txt(p_after, p_before, p_key)
  end;
$$;

-- Korean noun for an entity_type. Used by the generic fallback template so an
-- unknown command still produces a readable sentence for a known entity, and
-- degrades to the raw identifier when even that is new.
create or replace function wms._audit_entity_ko(p_entity_type text)
returns text
language sql immutable
as $$
  select case p_entity_type
    when 'purchase_order'              then '발주(PO)'
    when 'receipt'                     then '입고 건'
    when 'equipment'                   then '설비'
    when 'equipment_command'           then '설비 명령'
    when 'equipment_fault'             then '설비 장애'
    when 'work_order'                  then '업무 오더'
    when 'dispatch_wave'               then '디스패치 웨이브'
    when 'sortation_profile'           then '분류 프로파일'
    when 'wcs_routing_policy'          then '라우팅 정책'
    when 'wcs_routing_override'        then '라우팅 강제 제외'
    when 'outbound_order'              then '출고 오더'
    when 'dispatch_sequence'           then '출고 서열'
    when 'simulation_profile'          then '시뮬레이션 프로파일'
    when 'simulation_command_schedule' then '시뮬레이션 명령 일정'
    when 'simulation_scenario'         then 'what-if 시나리오'
    when 'simulation_scenario_run'     then 'what-if 시나리오 실행'
    when 'dock'                        then '도크'
    when 'dock_appointment'            then '도크 예약'
    when 'labor_activity'              then '인력 작업'
    when 'storage_location'            then '보관 위치'
    when 'sku_location_assignment'     then 'SKU 위치 배정'
    when 'slotting_class_policy'       then '슬롯팅 등급 정책'
    when 'slotting_recommendation'     then '슬롯팅 추천'
    when 'sku_velocity_batch'          then 'SKU 출고 속도 산출'
    when 'agent_decision'              then '에이전트 판단·제안'
    when 'audit_export'                then '감사 로그 내보내기'
    else coalesce(p_entity_type, '알 수 없는')
  end;
$$;

-- ============================================================
-- D1. wms.describe_audit_event — the read-time Korean summary.
--
-- IMMUTABLE and side-effect free: same inputs, same sentence, forever. Nothing
-- is stored. Change a template and every past event re-reads with the new
-- wording on the next SELECT; add a command and no backfill migration is owed
-- (which is precisely why the stored-column alternative was rejected in D1).
--
-- COVERAGE, counted rather than claimed:
--   65 of the 65 `command` values that any shipped migration actually writes
--   to wms.audit_events get a dedicated template, plus this contract's own
--   `wms_export_audit_log` = 66 specific branches.
--
--     $ grep -rhA3 'insert into wms.audit_events' supabase/migrations/ \
--         | grep -oE "'wms_[a-z_]+'" | sort -u | wc -l
--     65
--
--   The generic fallback is therefore dead code TODAY, on purpose. It exists
--   for the twelfth area: a new command must never make this function return
--   NULL, raise, or render a blank cell. D1 — "새 명령을 추가할 때마다 이 함수를
--   갱신하는 것이 요구사항이 아니라 개선 기회가 된다". The verify suite calls
--   it with a fabricated command precisely because nothing else can.
--
-- Two commands write TWO audit rows with different entity types
-- (wms_dock_vehicle and wms_depart_vehicle each write one for the appointment
-- and one for the door). Those branch on p_entity_type so the two rows do not
-- read as duplicates of each other.
-- ============================================================

create or replace function wms.describe_audit_event(
  p_command text,
  p_entity_type text,
  p_before jsonb,
  p_after jsonb,
  p_reasoning text default null
) returns text
language sql immutable
as $$
  select
    case p_command

      -- ---- area 1: procurement / inbound / quality (20260726) ----------
      when 'wms_create_rfq' then
        format('구매 요청(RFQ)이 생성되었다 — 수량 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'qty'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_submit_purchase_approval' then
        format('발주 승인 심사가 처리되었다 — 상태 %s%s.',
               wms._audit_txt(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_confirm_purchase_order' then
        format('발주(PO)가 확정되어 입고 예정이 생성되었다 — 수량 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'qty'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_register_arrival' then
        format('입고 예정 건의 차량 도착이 등록되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_receive' then
        format('입고 수량이 확정되었다 — 수령 %s / 예정 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'received_qty'),
               wms._audit_txt(p_after, p_before, 'expected_qty'),
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_record_quality_result' then
        format('품질 검사 결과가 기록되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_apply_disposition' then
        format('품질 불합격 재고에 폐기 처분이 적용되었다 — 처분 %s, 수량 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'disposition_type'),
               wms._audit_txt(p_after, p_before, 'qty'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_create_putaway_tasks' then
        format('검수 완료 재고의 적치가 처리되어 가용 재고로 전환되었다 — 처분 %s, 수량 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'disposition_type'),
               wms._audit_txt(p_after, p_before, 'qty'),
               wms._audit_txt(p_after, p_before, 'status'))

      -- ---- area 2: WCS equipment control (20260727) --------------------
      when 'wms_register_equipment' then
        format('설비 %s(%s)가 등록되었다 — 구역 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'equipment_code'),
               wms._audit_txt(p_after, p_before, 'equipment_type'),
               wms._audit_txt(p_after, p_before, 'zone_code'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_dispatch_equipment_command' then
        format('설비 명령(%s)이 하달되었다 — 상태 %s.',
               wms._audit_txt(p_after, p_before, 'command_type'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_cancel_equipment_command' then
        format('설비 명령이 취소되었다 — 상태 %s%s.',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_report_command_result' then
        format('설비가 명령 실행 결과를 보고했다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_report_equipment_status' then
        format('설비 상태가 보고되었다 — %s (설비 %s).',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_txt(p_after, p_before, 'equipment_code'))
      when 'wms_raise_equipment_fault' then
        format('설비 장애(%s)가 접수되었다 — 심각도 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'fault_code'),
               wms._audit_txt(p_after, p_before, 'severity'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_resolve_equipment_fault' then
        format('설비 장애가 해소 처리되었다 — 상태 %s%s.',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('조치', wms._audit_val(p_after, p_before, 'resolution_note')))

      -- ---- area 3: WES material flow control (20260728) ----------------
      when 'wms_open_dispatch_wave' then
        format('디스패치 웨이브가 개설되었다 — 상태 %s.',
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_release_dispatch_wave' then
        format('디스패치 웨이브가 릴리스되어 소속 업무 오더가 배차 대상이 되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_create_work_order' then
        format('업무 오더(%s)가 생성되었다 — 설비유형 %s, 구역 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'work_order_type'),
               wms._audit_txt(p_after, p_before, 'equipment_type'),
               wms._audit_txt(p_after, p_before, 'zone_code'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_dispatch_work_order' then
        format('업무 오더가 설비에 배차되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_retry_work_order_dispatch' then
        format('업무 오더 배차가 재시도되었다 — 상태 %s%s.',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_cancel_work_order' then
        format('업무 오더가 취소되었다 — 상태 %s%s.',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_propagate_command_result' then
        format('설비 명령 결과가 업무 오더에 반영되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))

      -- ---- area 4: high-speed sortation (20260729) ---------------------
      when 'wms_create_sortation_profile' then
        format('분류 프로파일이 생성되었다 — 속도 모드 %s, 최소 반송 간격 %smm.',
               wms._audit_txt(p_after, p_before, 'speed_mode'),
               wms._audit_txt(p_after, p_before, 'min_carton_gap_mm'))
      when 'wms_update_sortation_profile' then
        format('분류 프로파일이 변경되었다 — 속도 모드 %s, 최소 반송 간격 %smm.',
               wms._audit_chg(p_after, p_before, 'speed_mode'),
               wms._audit_chg(p_after, p_before, 'min_carton_gap_mm'))
      when 'wms_escalate_sortation_jam' then
        format('분류기 잼(jam)이 설비 장애로 에스컬레이션되었다 — 코드 %s, 심각도 %s.',
               wms._audit_txt(p_after, p_before, 'fault_code'),
               wms._audit_txt(p_after, p_before, 'severity'))

      -- ---- area 5: bottleneck-aware routing (20260730) -----------------
      when 'wms_register_wcs_routing_policy' then
        format('라우팅 정책이 등록되었다 — 설비유형 %s, 큐 임계 %s, 장애 임계 %s.',
               wms._audit_txt(p_after, p_before, 'equipment_type'),
               wms._audit_txt(p_after, p_before, 'queue_depth_threshold'),
               wms._audit_txt(p_after, p_before, 'fault_count_threshold'))
      when 'wms_update_wcs_routing_policy' then
        format('라우팅 정책이 변경되었다 — 설비유형 %s, 큐 임계 %s, 장애 임계 %s.',
               wms._audit_txt(p_after, p_before, 'equipment_type'),
               wms._audit_chg(p_after, p_before, 'queue_depth_threshold'),
               wms._audit_chg(p_after, p_before, 'fault_count_threshold'))
      when 'wms_exclude_equipment_from_routing' then
        format('설비가 라우팅 대상에서 강제 제외되었다 — 상태 %s%s.',
               wms._audit_txt(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_clear_equipment_routing_exclusion' then
        format('설비의 라우팅 강제 제외가 해제되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))

      -- ---- area 6: sequential dispatch / palletizing (20260731) --------
      when 'wms_create_outbound_order' then
        format('출고 오더(%s)가 생성되었다 — 점포 %s, 수량 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'order_number'),
               wms._audit_txt(p_after, p_before, 'store_code'),
               wms._audit_txt(p_after, p_before, 'qty'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_assign_dispatch_sequence' then
        format('출고 서열이 배정되었다 — 순번 %s, 파렛트 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'sequence_position'),
               wms._audit_txt(p_after, p_before, 'target_pallet_code'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_cancel_dispatch_sequence' then
        format('출고 서열이 취소되었다 — 상태 %s%s.',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_dispatch_palletize_command' then
        format('적재(팔레타이즈) 명령이 하달되었다 — 순번 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'sequence_position'),
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_propagate_palletize_result' then
        format('적재 명령 결과가 출고 서열·오더에 반영되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))

      -- ---- area 7: digital twin / simulation (20260801) ----------------
      when 'wms_register_simulation_profile' then
        format('시뮬레이션 프로파일이 등록되었다 — 실패율 %s, 잼 발생률 %s.',
               wms._audit_txt(p_after, p_before, 'failure_rate'),
               wms._audit_txt(p_after, p_before, 'jam_rate'))
      when 'wms_update_simulation_profile' then
        format('시뮬레이션 프로파일이 변경되었다 — 실패율 %s, 잼 발생률 %s.',
               wms._audit_chg(p_after, p_before, 'failure_rate'),
               wms._audit_chg(p_after, p_before, 'jam_rate'))
      when 'wms_set_equipment_simulation_mode' then
        format('설비의 시뮬레이션 모드가 전환되었다 — 설비 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'equipment_code'),
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_plan_simulated_command' then
        format('시뮬레이터가 명령 진행 일정을 수립했다 — 다음 상태 %s, 예정 종료 상태 %s.',
               wms._audit_txt(p_after, p_before, 'next_status'),
               wms._audit_txt(p_after, p_before, 'planned_terminal_status'))
      when 'wms_advance_simulated_command' then
        format('시뮬레이터가 명령 진행을 한 단계 진전시켰다 — 다음 상태 %s.',
               wms._audit_chg(p_after, p_before, 'next_status'))
      when 'wms_create_simulation_scenario' then
        format('what-if 시나리오(%s)가 정의되었다 — 유형 %s, 명령 %s건.',
               wms._audit_txt(p_after, p_before, 'name'),
               wms._audit_txt(p_after, p_before, 'scenario_type'),
               wms._audit_txt(p_after, p_before, 'command_count'))
      when 'wms_run_simulation_scenario' then
        format('what-if 시나리오가 실행되어 예측 결과가 산출되었다 — 예상 소요 %sms, 예상 실패 %s건.',
               wms._audit_txt(p_after, p_before, 'projected_duration_ms'),
               wms._audit_txt(p_after, p_before, 'projected_failure_count'))

      -- ---- area 8: yard / dock scheduling (20260802) -------------------
      when 'wms_register_dock' then
        format('도크 %s(%s)가 등록되었다 — 상태 %s.',
               wms._audit_txt(p_after, p_before, 'code'),
               wms._audit_txt(p_after, p_before, 'name'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_set_dock_status' then
        format('도크 %s의 상태가 변경되었다 — %s%s.',
               wms._audit_txt(p_after, p_before, 'code'),
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_schedule_dock_appointment' then
        format('도크 예약이 등록되었다 — 유형 %s, 운송사 %s, 차량 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'appointment_type'),
               wms._audit_txt(p_after, p_before, 'carrier_name'),
               wms._audit_txt(p_after, p_before, 'vehicle_plate_no'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_cancel_dock_appointment' then
        format('도크 예약이 취소되었다 — 차량 %s, 상태 %s%s.',
               wms._audit_txt(p_after, p_before, 'vehicle_plate_no'),
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))
      when 'wms_check_in_vehicle' then
        format('차량 %s이(가) 야드에 체크인했다 — 상태 %s.',
               wms._audit_txt(p_after, p_before, 'vehicle_plate_no'),
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_dock_vehicle' then
        case when p_entity_type = 'dock'
          then format('도크 %s에 차량이 접안해 도크가 점유 상태가 되었다 — %s.',
                      wms._audit_txt(p_after, p_before, 'code'),
                      wms._audit_chg(p_after, p_before, 'status'))
          else format('예약 차량 %s이(가) 도크에 접안했다 — 상태 %s.',
                      wms._audit_txt(p_after, p_before, 'vehicle_plate_no'),
                      wms._audit_chg(p_after, p_before, 'status'))
        end
      when 'wms_depart_vehicle' then
        case when p_entity_type = 'dock'
          then format('도크 %s에서 차량이 출차해 도크가 해제되었다 — %s.',
                      wms._audit_txt(p_after, p_before, 'code'),
                      wms._audit_chg(p_after, p_before, 'status'))
          else format('예약 차량 %s이(가) 출차했다 — 상태 %s.',
                      wms._audit_txt(p_after, p_before, 'vehicle_plate_no'),
                      wms._audit_chg(p_after, p_before, 'status'))
        end

      -- ---- area 9: labor management (20260803) -------------------------
      when 'wms_start_labor_activity' then
        format('인력 작업(%s)이 시작되었다 — %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'activity_type'),
               wms._audit_txt(p_after, p_before, 'activity_label'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_complete_labor_activity' then
        format('인력 작업이 완료되었다 — 처리 %s건, 소요 %s초, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'unit_count'),
               wms._audit_txt(p_after, p_before, 'duration_seconds'),
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_cancel_labor_activity' then
        format('인력 작업이 취소되었다 — 상태 %s%s.',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('사유', wms._audit_val(p_after, p_before, 'reason')))

      -- ---- area 10: slotting optimization (20260804) -------------------
      when 'wms_register_storage_location' then
        format('보관 위치 %s가 등록되었다 — 구역 %s, 접근등급 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'location_code'),
               wms._audit_txt(p_after, p_before, 'zone_code'),
               wms._audit_txt(p_after, p_before, 'accessibility_rank'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_set_storage_location_status' then
        format('보관 위치 %s의 상태가 변경되었다 — %s.',
               wms._audit_txt(p_after, p_before, 'location_code'),
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_register_slotting_class_policy' then
        format('슬롯팅 등급 정책이 등록되었다 — 등급 %s, 허용 최대 접근등급 %s.',
               wms._audit_txt(p_after, p_before, 'velocity_class'),
               wms._audit_txt(p_after, p_before, 'max_accessibility_rank'))
      when 'wms_update_slotting_class_policy' then
        format('슬롯팅 등급 정책이 변경되었다 — 등급 %s, 허용 최대 접근등급 %s.',
               wms._audit_txt(p_after, p_before, 'velocity_class'),
               wms._audit_chg(p_after, p_before, 'max_accessibility_rank'))
      when 'wms_compute_sku_velocity' then
        format('SKU 출고 속도(velocity)가 재계산되었다 — 관찰 기간 %s ~ %s.',
               wms._audit_txt(p_after, p_before, 'window_start'),
               wms._audit_txt(p_after, p_before, 'window_end'))
      when 'wms_generate_slotting_recommendations' then
        format('슬롯팅 재배치 추천이 생성되었다 — 사유 코드 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'reason_code'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_review_slotting_recommendation' then
        format('슬롯팅 추천이 검토되었다 — 상태 %s%s.',
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('검토 의견', wms._audit_val(p_after, p_before, 'review_reason')))
      when 'wms_apply_slotting_recommendation' then
        format('승인된 슬롯팅 추천이 적용되어 SKU 보관 위치가 재배치되었다 — 상태 %s.',
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_assign_sku_location' then
        format('SKU에 보관 위치가 배정되었다%s.',
               wms._audit_opt('배정 사유', wms._audit_val(p_after, p_before, 'assigned_reason')))
      when 'wms_reassign_sku_location' then
        format('SKU의 보관 위치가 재배정되었다%s.',
               wms._audit_opt('배정 사유', wms._audit_val(p_after, p_before, 'assigned_reason')))

      -- ---- area 11: agentic operations (20260805) ----------------------
      -- These four are the events most likely to carry a `reasoning` join
      -- (D3): the agent files a decision under the same correlation_id as the
      -- action it took, so the "(사유: ...)" suffix below lands here first.
      when 'wms_log_agent_decision' then
        format('에이전트가 자율 실행한 조치의 판단 근거를 기록했다 — 유형 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'proposal_type'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_propose_agent_action' then
        format('에이전트가 사람 검토용 조치를 제안했다 — 유형 %s, 상태 %s.',
               wms._audit_txt(p_after, p_before, 'proposal_type'),
               wms._audit_txt(p_after, p_before, 'status'))
      when 'wms_confirm_agent_proposal' then
        format('사람이 에이전트 제안을 승인했다 — 유형 %s, 상태 %s (승인은 상태 전이일 뿐 조치가 자동 실행되지는 않는다).',
               wms._audit_txt(p_after, p_before, 'proposal_type'),
               wms._audit_chg(p_after, p_before, 'status'))
      when 'wms_reject_agent_proposal' then
        format('사람이 에이전트 제안을 반려했다 — 유형 %s, 상태 %s%s.',
               wms._audit_txt(p_after, p_before, 'proposal_type'),
               wms._audit_chg(p_after, p_before, 'status'),
               wms._audit_opt('반려 사유', wms._audit_val(p_after, p_before, 'rejection_reason')))

      -- ---- area 11 (this contract): the self-audit row (D4) ------------
      when 'wms_export_audit_log' then
        format('감사 로그 %s건이 내보내졌다 — 기간 %s ~ %s%s%s.',
               wms._audit_txt(p_after, p_before, 'exported_row_count'),
               coalesce(wms._audit_val(p_after, p_before, 'date_from'), '(처음)'),
               coalesce(wms._audit_val(p_after, p_before, 'date_to'), '(현재)'),
               wms._audit_opt('명령 필터', wms._audit_val(p_after, p_before, 'command')),
               wms._audit_opt('엔티티 필터', wms._audit_val(p_after, p_before, 'entity_type')))

      -- ---- generic fallback (D1) ---------------------------------------
      else
        format('%s 엔티티에 대해 %s 명령이 실행되었다.',
               wms._audit_entity_ko(p_entity_type),
               coalesce(p_command, '(이름 없는)'))
    end
    ||
    case
      when p_reasoning is null or btrim(p_reasoning) = '' then ''
      else format(' (사유: %s)', btrim(p_reasoning))
    end;
$$;

comment on function wms.describe_audit_event(text, text, jsonb, jsonb, text) is
  'Deterministic Korean one-line summary of a wms.audit_events row. Computed at '
  'read time, never stored (design.md D1). Never returns NULL: unknown commands '
  'fall through to a generic template.';

-- ============================================================
-- D2. The role gate.
--
-- The existing `audit_events_select` policy is NOT touched: an
-- INBOUND_OPERATOR can still SELECT raw wms.audit_events for their tenant,
-- exactly as before, and other screens that rely on that keep working. What
-- is gated is this contract's surface — summarised, filtered, exportable —
-- because that is a different risk profile from raw JSONB one row at a time.
--
-- AUDITOR is not a new role. It has been in the schema comment since
-- 20260726 line 30 as part of design.md §12's role list, and no RPC has ever
-- checked it. This contract is its first real use — paying off a documented
-- debt rather than inventing an eleventh role. WMS_ADMIN rides along under
-- the repo-wide "admin is always a superset" convention.
-- ============================================================

create or replace function wms._audit_require_reader(p_tenant_id uuid)
returns void
language plpgsql stable security definer
set search_path = wms, public
as $$
begin
  if p_tenant_id is null then
    raise exception 'INVALID: tenant_id is required';
  end if;
  -- has_role() is membership-scoped, so this also IS the cross-tenant check:
  -- a tenant-A auditor asking about tenant B has no membership row there and
  -- is refused before a single event is read.
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'AUDITOR') then
    raise exception
      'FORBIDDEN: role cannot read the operations audit log (WMS_ADMIN or AUDITOR required)';
  end if;
end;
$$;

-- Shared filter validation, so the two RPCs cannot drift apart on what counts
-- as a legal request.
create or replace function wms._audit_validate_filters(
  p_date_from timestamptz,
  p_date_to timestamptz
) returns void
language plpgsql immutable
as $$
begin
  if p_date_from is not null and p_date_to is not null and p_date_from > p_date_to then
    raise exception 'INVALID: date_from must not be after date_to';
  end if;
end;
$$;

-- ============================================================
-- wms.wms_query_audit_log — filtered, paginated, summarised read.
--
-- `p_date_to` is INCLUSIVE (`created_at <= p_date_to`). A caller passing a
-- bare date gets that day's midnight; the frontend therefore sends an
-- end-of-day timestamp, and the verify suite pins the boundary behaviour.
-- ============================================================

create or replace function wms.wms_query_audit_log(
  p_tenant_id uuid,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_actor_id uuid default null,
  p_entity_type text default null,
  p_entity_id uuid default null,
  p_command text default null,
  p_correlation_id text default null,
  p_limit int default 50,
  p_offset int default 0
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_rows jsonb;
  v_total int;
  v_facets jsonb;
begin
  perform wms._audit_require_reader(p_tenant_id);
  perform wms._audit_validate_filters(p_date_from, p_date_to);

  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'INVALID: limit must be between 1 and 500 (got %)', coalesce(p_limit::text, 'null');
  end if;
  if p_offset is null or p_offset < 0 then
    raise exception 'INVALID: offset must be >= 0 (got %)', coalesce(p_offset::text, 'null');
  end if;

  -- Counted separately rather than with count(*) over(): the window function
  -- would return nothing at all on a page past the end, and a paginator that
  -- loses its total the moment you overshoot is worse than useless.
  select count(*)::int into v_total
  from wms.audit_events e
  where e.tenant_id = p_tenant_id
    and (p_date_from      is null or e.created_at    >= p_date_from)
    and (p_date_to        is null or e.created_at    <= p_date_to)
    and (p_actor_id       is null or e.actor_id       = p_actor_id)
    and (p_entity_type    is null or e.entity_type    = p_entity_type)
    and (p_entity_id      is null or e.entity_id      = p_entity_id)
    and (p_command        is null or e.command        = p_command)
    and (p_correlation_id is null or e.correlation_id = p_correlation_id);

  select coalesce(jsonb_agg(t.item order by t.ord), '[]'::jsonb)
  into v_rows
  from (
    select
      row_number() over (order by e.created_at desc, e.id desc) as ord,
      jsonb_build_object(
        'event_id',              e.id,
        'created_at',            e.created_at,
        'actor_id',              e.actor_id,
        'actor_email',           u.email,
        'command',               e.command,
        'entity_type',           e.entity_type,
        'entity_id',             e.entity_id,
        'correlation_id',        e.correlation_id,
        'before',                e.before,
        'after',                 e.after,
        -- D3 / V2: the agent-reasoning join, and the only place this contract
        -- touches wms.agent_decisions. It reads; it never writes.
        'agent_decision_id',     ad.id,
        'agent_decision_status', ad.status,
        'agent_reasoning',       ad.reasoning,
        'has_agent_reasoning',   ad.reasoning is not null,
        'summary_ko',            wms.describe_audit_event(
                                   e.command, e.entity_type, e.before, e.after, ad.reasoning)
      ) as item
    from wms.audit_events e
    left join auth.users u on u.id = e.actor_id
    left join lateral (
      -- V3: at most one decision per event, most recent wins, tenant-scoped.
      select d.id, d.reasoning, d.status
      from wms.agent_decisions d
      where e.correlation_id is not null
        and d.correlation_id = e.correlation_id
        and d.tenant_id      = e.tenant_id
      order by d.created_at desc, d.id desc
      limit 1
    ) ad on true
    where e.tenant_id = p_tenant_id
      and (p_date_from      is null or e.created_at    >= p_date_from)
      and (p_date_to        is null or e.created_at    <= p_date_to)
      and (p_actor_id       is null or e.actor_id       = p_actor_id)
      and (p_entity_type    is null or e.entity_type    = p_entity_type)
      and (p_entity_id      is null or e.entity_id      = p_entity_id)
      and (p_command        is null or e.command        = p_command)
      and (p_correlation_id is null or e.correlation_id = p_correlation_id)
    order by e.created_at desc, e.id desc
    limit p_limit offset p_offset
  ) t;

  -- V6: filter vocabulary, computed over the tenant's WHOLE log rather than
  -- the filtered page. A caller building a filter UI has no other way to learn
  -- that `wms_confirm_purchase_order` is a legal value for p_command — deriving
  -- the dropdowns from the current page would make the options vanish as soon
  -- as the filter narrowed, which is the opposite of what a filter is for.
  -- Three grouped scans on an indexed table; this is a demo app, not a
  -- warehouse-scale log store, and the alternative was a hard-coded list of 65
  -- command names duplicated in the frontend.
  select jsonb_build_object(
    'commands', coalesce((
      select jsonb_agg(distinct e.command order by e.command)
      from wms.audit_events e where e.tenant_id = p_tenant_id), '[]'::jsonb),
    'entity_types', coalesce((
      select jsonb_agg(distinct e.entity_type order by e.entity_type)
      from wms.audit_events e where e.tenant_id = p_tenant_id), '[]'::jsonb),
    'actors', coalesce((
      select jsonb_agg(jsonb_build_object('actor_id', a.actor_id, 'actor_email', u.email)
                       order by u.email nulls last)
      from (select distinct e.actor_id from wms.audit_events e
             where e.tenant_id = p_tenant_id and e.actor_id is not null) a
      left join auth.users u on u.id = a.actor_id), '[]'::jsonb)
  ) into v_facets;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'filter', jsonb_build_object(
      'date_from', p_date_from, 'date_to', p_date_to, 'actor_id', p_actor_id,
      'entity_type', p_entity_type, 'entity_id', p_entity_id, 'command', p_command,
      'correlation_id', p_correlation_id),
    'facets', v_facets,
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'total_count', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'page_count', case when v_total = 0 then 0 else ceil(v_total::numeric / p_limit)::int end,
    'has_more', p_offset + jsonb_array_length(v_rows) < v_total
  );
end;
$$;

-- ============================================================
-- wms.wms_export_audit_log — same filters, no pagination, self-audited (D4).
--
-- Two things make this different from a query with a big limit:
--   * the safety cap (D5 / V5) refuses instead of truncating, so an export can
--     never silently be a partial export;
--   * the call itself lands in wms.audit_events, so "who downloaded the audit
--     log, when, filtered how" is itself auditable. It is VOLATILE for that
--     reason — the only writing function in this contract, and all it writes
--     is one row about itself.
-- ============================================================

create or replace function wms.wms_export_audit_log(
  p_tenant_id uuid,
  p_date_from timestamptz default null,
  p_date_to timestamptz default null,
  p_actor_id uuid default null,
  p_entity_type text default null,
  p_entity_id uuid default null,
  p_command text default null,
  p_correlation_id text default null,
  p_max_rows int default 10000
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  -- D5. Hard ceiling. p_max_rows may lower it, never raise it.
  c_hard_cap constant int := 10000;
  v_rows jsonb;
  v_total int;
  v_filter jsonb;
  v_export_id uuid;
begin
  perform wms._audit_require_reader(p_tenant_id);
  perform wms._audit_validate_filters(p_date_from, p_date_to);

  if p_max_rows is null or p_max_rows < 1 or p_max_rows > c_hard_cap then
    raise exception 'INVALID: max_rows must be between 1 and % (got %)',
      c_hard_cap, coalesce(p_max_rows::text, 'null');
  end if;

  select count(*)::int into v_total
  from wms.audit_events e
  where e.tenant_id = p_tenant_id
    and (p_date_from      is null or e.created_at    >= p_date_from)
    and (p_date_to        is null or e.created_at    <= p_date_to)
    and (p_actor_id       is null or e.actor_id       = p_actor_id)
    and (p_entity_type    is null or e.entity_type    = p_entity_type)
    and (p_entity_id      is null or e.entity_id      = p_entity_id)
    and (p_command        is null or e.command        = p_command)
    and (p_correlation_id is null or e.correlation_id = p_correlation_id);

  if v_total > p_max_rows then
    raise exception
      'INVALID: export matches % events, over the % row safety limit — narrow the date range or add a filter',
      v_total, p_max_rows;
  end if;

  select coalesce(jsonb_agg(t.item order by t.ord), '[]'::jsonb)
  into v_rows
  from (
    select
      row_number() over (order by e.created_at desc, e.id desc) as ord,
      jsonb_build_object(
        'event_id',              e.id,
        'created_at',            e.created_at,
        'actor_id',              e.actor_id,
        'actor_email',           u.email,
        'command',               e.command,
        'entity_type',           e.entity_type,
        'entity_id',             e.entity_id,
        'correlation_id',        e.correlation_id,
        'before',                e.before,
        'after',                 e.after,
        'agent_decision_id',     ad.id,
        'agent_decision_status', ad.status,
        'agent_reasoning',       ad.reasoning,
        'has_agent_reasoning',   ad.reasoning is not null,
        'summary_ko',            wms.describe_audit_event(
                                   e.command, e.entity_type, e.before, e.after, ad.reasoning)
      ) as item
    from wms.audit_events e
    left join auth.users u on u.id = e.actor_id
    left join lateral (
      select d.id, d.reasoning, d.status
      from wms.agent_decisions d
      where e.correlation_id is not null
        and d.correlation_id = e.correlation_id
        and d.tenant_id      = e.tenant_id
      order by d.created_at desc, d.id desc
      limit 1
    ) ad on true
    where e.tenant_id = p_tenant_id
      and (p_date_from      is null or e.created_at    >= p_date_from)
      and (p_date_to        is null or e.created_at    <= p_date_to)
      and (p_actor_id       is null or e.actor_id       = p_actor_id)
      and (p_entity_type    is null or e.entity_type    = p_entity_type)
      and (p_entity_id      is null or e.entity_id      = p_entity_id)
      and (p_command        is null or e.command        = p_command)
      and (p_correlation_id is null or e.correlation_id = p_correlation_id)
    order by e.created_at desc, e.id desc
  ) t;

  -- D4. The self-audit row. Written AFTER the rows above were materialised, so
  -- an export never contains itself — a reader gets the export they asked for,
  -- and the record of it appears on the NEXT query (which is exactly the
  -- scenario spec.md describes).
  v_filter := jsonb_strip_nulls(jsonb_build_object(
    'date_from',      p_date_from,
    'date_to',        p_date_to,
    'actor_id',       p_actor_id,
    'entity_type',    p_entity_type,
    'entity_id',      p_entity_id,
    'command',        p_command,
    'correlation_id', p_correlation_id,
    'max_rows',       p_max_rows));

  insert into wms.audit_events
    (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values
    (p_tenant_id,
     auth.uid(),                       -- V4: the caller, not the actor filter
     'wms_export_audit_log',
     'audit_export',
     null,
     null,
     v_filter || jsonb_build_object('exported_row_count', v_total),
     p_correlation_id)
  returning id into v_export_id;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'filter', v_filter,
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'total_count', v_total,
    'max_rows', p_max_rows,
    'self_audit_event_id', v_export_id,
    'exported_by', auth.uid()
  );
end;
$$;

-- ============================================================
-- Grants. Execution is open to `authenticated` and the role check lives
-- inside the function — the same shape as every other RPC in this repo. The
-- `_audit_*` helpers are granted too because describe_audit_event calls them
-- and it is itself callable directly (the frontend does not need that, but a
-- reviewer poking at one row in psql does).
-- ============================================================

grant execute on function wms._audit_val(jsonb, jsonb, text) to authenticated;
grant execute on function wms._audit_txt(jsonb, jsonb, text) to authenticated;
grant execute on function wms._audit_opt(text, text) to authenticated;
grant execute on function wms._audit_chg(jsonb, jsonb, text) to authenticated;
grant execute on function wms._audit_entity_ko(text) to authenticated;
grant execute on function wms.describe_audit_event(text, text, jsonb, jsonb, text) to authenticated;
grant execute on function wms.wms_query_audit_log(
  uuid, timestamptz, timestamptz, uuid, text, uuid, text, text, int, int) to authenticated;
grant execute on function wms.wms_export_audit_log(
  uuid, timestamptz, timestamptz, uuid, text, uuid, text, text, int) to authenticated;

-- The two internal guards stay ungranted, matching wms._wms_load_agent_proposal
-- and wms._wms_pick_equipment_for_work_order.

-- ============================================================
-- Index. Every filter combination this contract offers starts from
-- (tenant_id, created_at desc) — the paginator's ORDER BY is that pair — and
-- wms.audit_events had no index at all beyond its primary key after eleven
-- migrations of appending to it.
-- ============================================================

create index if not exists audit_events_tenant_created_idx
  on wms.audit_events (tenant_id, created_at desc, id desc);
create index if not exists audit_events_correlation_idx
  on wms.audit_events (correlation_id) where correlation_id is not null;

-- The other half of the D3 join is already indexed by its owner
-- (`agent_decisions_correlation_idx`, 20260805 line 302), so this contract
-- adds nothing to wms.agent_decisions — it only reads that table.
