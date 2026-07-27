<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Natural-language operations audit log
// (openspec change add-operations-audit-log).
//
// Nothing on this page is new data. Every row was written by one of the ~65
// write RPCs the ten earlier areas already ship, into the wms.audit_events
// table that has existed since the first migration. What this screen adds is
// the two things that table was missing for a human reader:
//
//   1. A SENTENCE. `summary_ko` comes from wms.describe_audit_event(), a
//      deterministic IMMUTABLE Postgres function — not an LLM, not a
//      client-side template. That matters here more than usual: if the
//      frontend and the MCP server each formatted their own sentence, two
//      auditors reading the same event through two surfaces would get two
//      different accounts of it.
//   2. THE AGENT'S REASON. Where an event shares a correlation_id with a
//      wms.agent_decisions row, the agent's own `reasoning` is joined in and
//      shown next to the action it justified. "What happened" and "why" are
//      one row, which is the entire point of the catalogue item this contract
//      implements.
//
// Access is WMS_ADMIN / AUDITOR only. The nav link is hidden for everyone else
// and this component refuses to call the RPC — but neither of those is the
// control. The control is wms.has_role() inside the two SECURITY DEFINER
// functions, which is why the E2E suite signs in as a buyer and checks the
// RPC refuses, not just that the button is missing.

const auth = useAuthStore()

const canAudit = computed(() => ['WMS_ADMIN', 'AUDITOR'].includes(auth.currentRole ?? ''))

const data = ref<any>(null)
const loading = ref(false)
const exporting = ref(false)
const error = ref('')
const notice = ref('')

const PAGE_SIZE = 20

const dateFrom = ref('')
const dateTo = ref('')
const actorId = ref('')
const entityType = ref('')
const command = ref('')
const correlationId = ref('')
const offset = ref(0)

const rows = computed(() => data.value?.rows ?? [])
const facets = computed(() => data.value?.facets ?? { commands: [], entity_types: [], actors: [] })
const totalCount = computed(() => Number(data.value?.total_count ?? 0))
const pageCount = computed(() => Number(data.value?.page_count ?? 0))
const currentPage = computed(() => (totalCount.value === 0 ? 0 : Math.floor(offset.value / PAGE_SIZE) + 1))
const hasMore = computed(() => !!data.value?.has_more)
const reasoningCount = computed(
  () => rows.value.filter((r: any) => r.has_agent_reasoning).length,
)

/**
 * A <input type="date"> gives a bare day in the browser's local timezone.
 * `date_to` on the RPC is inclusive, so the end of a day has to be sent as the
 * end of that day — sending bare midnight would silently drop everything that
 * happened after 00:00:00 on the last day of the range, which looks like data
 * loss rather than an off-by-one.
 */
function startOfDay(value: string): string | null {
  return value ? new Date(`${value}T00:00:00`).toISOString() : null
}
function endOfDay(value: string): string | null {
  return value ? new Date(`${value}T23:59:59.999`).toISOString() : null
}

function filterParams() {
  return {
    p_tenant_id: auth.currentTenantId,
    p_date_from: startOfDay(dateFrom.value),
    p_date_to: endOfDay(dateTo.value),
    p_actor_id: actorId.value || null,
    p_entity_type: entityType.value || null,
    p_entity_id: null,
    p_command: command.value || null,
    p_correlation_id: correlationId.value.trim() || null,
  }
}

async function load() {
  if (!auth.currentTenantId || !canAudit.value) return
  loading.value = true
  error.value = ''
  try {
    const { data: res, error: rpcError } = await supabase.rpc('wms_query_audit_log', {
      ...filterParams(),
      p_limit: PAGE_SIZE,
      p_offset: offset.value,
    })
    if (rpcError) throw rpcError
    data.value = res
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

function applyFilters() {
  offset.value = 0
  return load()
}

function resetFilters() {
  dateFrom.value = ''
  dateTo.value = ''
  actorId.value = ''
  entityType.value = ''
  command.value = ''
  correlationId.value = ''
  return applyFilters()
}

function nextPage() {
  if (!hasMore.value) return
  offset.value += PAGE_SIZE
  return load()
}

function prevPage() {
  if (offset.value === 0) return
  offset.value = Math.max(0, offset.value - PAGE_SIZE)
  return load()
}

const CSV_COLUMNS = [
  'created_at',
  'actor_email',
  'command',
  'entity_type',
  'entity_id',
  'correlation_id',
  'summary_ko',
  'agent_reasoning',
]

function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? '' : String(value)
  return `"${text.replace(/"/g, '""')}"`
}

/**
 * The RPC returns rows; turning them into a file is the caller's job (design
 * Non-Goal: this app is not a reporting engine). A BOM is prepended because
 * the summaries are Korean and Excel on Windows reads a BOM-less UTF-8 CSV as
 * cp949 — the file would open as mojibake for exactly the finance reader this
 * contract exists to serve.
 */
function downloadCsv(exportRows: any[]) {
  const lines = [CSV_COLUMNS.join(',')]
  for (const r of exportRows) lines.push(CSV_COLUMNS.map((c) => csvCell(r[c])).join(','))
  const blob = new Blob([`﻿${lines.join('\r\n')}`], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `wms-audit-log-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '')}.csv`
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

async function exportCsv() {
  if (!auth.currentTenantId || !canAudit.value) return
  exporting.value = true
  error.value = ''
  notice.value = ''
  try {
    const { data: res, error: rpcError } = await supabase.rpc('wms_export_audit_log', {
      ...filterParams(),
      p_correlation_id: correlationId.value.trim() || null,
      p_max_rows: 10000,
    })
    if (rpcError) throw rpcError
    downloadCsv(res.rows ?? [])
    notice.value =
      `${res.row_count}건을 CSV로 내보냈습니다. ` +
      `이 내보내기 자체도 감사 이벤트로 기록되었습니다 — 아래 목록을 새로고침하면 ` +
      `wms_export_audit_log 행이 맨 위에 나타납니다.`
    // Reload so the self-audit row is visible immediately: an auditor should
    // see that their own download was recorded, not be told it was.
    offset.value = 0
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    exporting.value = false
  }
}

function when(ts: string | null) {
  if (!ts) return '—'
  return new Date(ts).toLocaleString('ko-KR', { hour12: false })
}

function shortId(id: string | null) {
  return id ? id.slice(0, 8) : '—'
}

function pretty(value: unknown) {
  if (value === null || value === undefined) return '—'
  return JSON.stringify(value, null, 2)
}

onMounted(load)
watch(() => auth.currentTenantId, applyFilters)
</script>

<template>
  <div>
    <h1>Audit Log</h1>
    <p class="hint">
      모든 쓰기 명령이 <code>wms.audit_events</code>에 남긴 구조화된 이력을 한국어 문장으로
      읽는 화면입니다. 요약 문장은 데이터베이스 안의 결정론적 함수
      (<code>wms.describe_audit_event</code>)가 조회 시점에 만들며, 저장되지 않고 LLM도
      쓰지 않습니다. 현재 역할: {{ auth.currentRole }}
    </p>

    <div v-if="!canAudit" class="card no-access" data-testid="audit-no-access">
      <h2>열람 권한이 없습니다</h2>
      <p>
        감사 로그 조회·내보내기는 <b>WMS_ADMIN</b> 또는 <b>AUDITOR</b> 역할만 사용할 수 있습니다
        (<code>{{ auth.currentRole }}</code> 역할로는 조회 RPC가 <code>FORBIDDEN</code>을 반환합니다).
      </p>
      <p class="hint">
        원본 <code>wms.audit_events</code> 테이블에 대한 직접 열람 권한은 이 제한과 무관하게
        기존 그대로 유지됩니다 — 좁힌 것은 요약·필터·내보내기가 붙은 이 표면뿐입니다.
      </p>
    </div>

    <template v-else>
      <div v-if="error" class="error-banner" data-testid="audit-error">{{ error }}</div>
      <div v-if="notice" class="notice-banner" data-testid="audit-notice">{{ notice }}</div>

      <div class="card filter-card">
        <div class="row">
          <label>
            시작일
            <input v-model="dateFrom" type="date" aria-label="Date From" />
          </label>
          <label>
            종료일
            <input v-model="dateTo" type="date" aria-label="Date To" />
          </label>
          <label>
            행위자
            <select v-model="actorId" aria-label="Actor Filter">
              <option value="">(전체)</option>
              <option v-for="a in facets.actors" :key="a.actor_id" :value="a.actor_id">
                {{ a.actor_email ?? a.actor_id }}
              </option>
            </select>
          </label>
          <label>
            엔티티 종류
            <select v-model="entityType" aria-label="Entity Type Filter">
              <option value="">(전체)</option>
              <option v-for="t in facets.entity_types" :key="t" :value="t">{{ t }}</option>
            </select>
          </label>
          <label>
            명령
            <select v-model="command" aria-label="Command Filter">
              <option value="">(전체)</option>
              <option v-for="c in facets.commands" :key="c" :value="c">{{ c }}</option>
            </select>
          </label>
          <label>
            상관관계 ID
            <input v-model="correlationId" aria-label="Correlation Id Filter" placeholder="correlation_id" />
          </label>
          <button class="primary" :disabled="loading" @click="applyFilters">Search</button>
          <button class="primary ghost" :disabled="loading" @click="resetFilters">Reset</button>
          <button
            class="primary"
            :disabled="exporting || loading"
            data-testid="audit-export"
            @click="exportCsv"
          >
            {{ exporting ? 'Exporting…' : 'Export CSV' }}
          </button>
        </div>
        <p class="hint">
          내보내기는 현재 필터 조건에 매칭되는 <b>전체</b> 행을 한 번에 받습니다(안전 상한 10,000건,
          초과하면 잘라내지 않고 거절합니다). 내보내기 호출 자체도 감사 이벤트로 남습니다.
        </p>
      </div>

      <p class="hint summary-line">
        전체 <b data-testid="audit-total">{{ totalCount }}</b>건 ·
        페이지 <b data-testid="audit-page">{{ currentPage }}</b> / {{ pageCount }} ·
        이 페이지 <b data-testid="audit-rowcount">{{ rows.length }}</b>건 ·
        판단 근거가 붙은 행 <b data-testid="audit-reasoning-count">{{ reasoningCount }}</b>건
      </p>

      <table>
        <thead>
          <tr>
            <th>시각</th>
            <th>행위자</th>
            <th>명령</th>
            <th>엔티티</th>
            <th>요약 (자동 생성)</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="r in rows"
            :key="r.event_id"
            :data-event-id="r.event_id"
            :data-command="r.command"
            :data-entity-type="r.entity_type"
            :data-has-reasoning="String(r.has_agent_reasoning)"
          >
            <td class="nowrap">{{ when(r.created_at) }}</td>
            <td>{{ r.actor_email ?? shortId(r.actor_id) }}</td>
            <td class="mono">{{ r.command }}</td>
            <td>
              {{ r.entity_type }}
              <span class="hint block mono">{{ shortId(r.entity_id) }}</span>
            </td>
            <td class="summary-cell">
              <span class="summary-ko">{{ r.summary_ko }}</span>
              <div v-if="r.has_agent_reasoning" class="reasoning">
                <span class="status warn">에이전트 판단 근거</span>
                <span class="reasoning-text">{{ r.agent_reasoning }}</span>
                <span class="hint block">
                  correlation_id <code>{{ r.correlation_id }}</code> ·
                  판단 기록 상태 {{ r.agent_decision_status }}
                </span>
              </div>
              <details v-if="r.before || r.after">
                <summary>원본 변경 전/후 (JSONB)</summary>
                <pre class="json">before: {{ pretty(r.before) }}
after:  {{ pretty(r.after) }}</pre>
              </details>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-if="!loading && rows.length === 0" data-testid="audit-empty">
        해당 조건에 맞는 감사 이벤트가 없습니다.
      </p>

      <div class="row pager">
        <button class="primary ghost" :disabled="offset === 0 || loading" @click="prevPage">
          ← 이전
        </button>
        <button
          class="primary ghost"
          :disabled="!hasMore || loading"
          data-testid="audit-next"
          @click="nextPage"
        >
          다음 →
        </button>
      </div>
    </template>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
.hint.block {
  display: block;
  margin: 0.15rem 0 0;
  font-size: 0.75rem;
}
.summary-line {
  margin: 0.75rem 0 0.5rem;
}
h2 {
  font-size: 1rem;
  margin: 0 0 0.4rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  flex-wrap: wrap;
}
.row.pager {
  margin-top: 0.75rem;
}
label {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  font-size: 0.8rem;
  color: var(--muted);
}
input,
select {
  padding: 0.4rem;
  border: 1px solid var(--line);
  border-radius: 6px;
}
.filter-card {
  margin-top: 0.75rem;
}
.filter-card .hint {
  margin: 0.6rem 0 0;
  font-size: 0.8rem;
}
button.primary.ghost {
  background: white;
  color: var(--accent);
  border: 1px solid var(--line);
}
.no-access {
  border-left: 4px solid #dc2626;
}
.summary-cell {
  max-width: 44rem;
}
.summary-ko {
  line-height: 1.5;
}
.reasoning {
  margin-top: 0.4rem;
  padding: 0.45rem 0.6rem;
  background: #fffbeb;
  border-left: 3px solid #f59e0b;
  border-radius: 4px;
}
.reasoning-text {
  display: block;
  margin-top: 0.25rem;
  font-size: 0.85rem;
  line-height: 1.45;
}
.json {
  background: #f8fafc;
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 0.6rem;
  font-size: 0.72rem;
  overflow-x: auto;
  margin: 0.4rem 0 0;
  white-space: pre-wrap;
}
details summary {
  cursor: pointer;
  font-size: 0.8rem;
  color: var(--accent);
  margin-top: 0.35rem;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85em;
}
.nowrap {
  white-space: nowrap;
}
.notice-banner {
  background: #dcfce7;
  color: #166534;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
</style>
