// Builds the 에이전틱 운영 운영자 매뉴얼 (.docx) from the screenshots captured by
// frontend/playwright/e2e/agent-decisions-flow.spec.ts.
//
//   npm install -g docx      # or a local `npm install docx`
//   node build_manual.mjs
//
// Every screenshot in this manual is a real frame from a passing Playwright
// run against a live local Supabase — nothing here is mocked up.

import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

// ESM ignores NODE_PATH, so fall back to the global install explicitly —
// keeps this script dependency-free next to the spec it documents.
const require = createRequire(import.meta.url)
function loadDocx() {
  try {
    return require('docx')
  } catch {
    const globalRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()
    return require(path.join(globalRoot, 'docx'))
  }
}
const {
  Document, Packer, Paragraph, TextRun, ImageRun, Header, Footer, AlignmentType,
  HeadingLevel, PageNumber, PageBreak, Table, TableRow, TableCell, BorderStyle,
  WidthType, ShadingType, LevelFormat, TableOfContents,
} = loadDocx()

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SHOTS = path.resolve(HERE, '../e2e/screenshots')
const OUT = path.resolve(HERE, 'agentic-operations-operator-manual.docx')

// US Letter, 1" margins -> 9360 DXA of content width.
const CONTENT_DXA = 9360
const IMG_W = 624
const border = { style: BorderStyle.SINGLE, size: 1, color: 'CCCCCC' }
const borders = { top: border, bottom: border, left: border, right: border }

function body(text, opts = {}) {
  return new Paragraph({ spacing: { after: 140 }, children: [new TextRun({ text, ...opts })] })
}

function bullet(text) {
  return new Paragraph({
    numbering: { reference: 'bullets', level: 0 },
    spacing: { after: 60 },
    children: [new TextRun(text)],
  })
}

function shot(file, caption) {
  const abs = path.join(SHOTS, file)
  const { width, height } = pngSize(abs)
  const h = Math.round((height / width) * IMG_W)
  return [
    new Paragraph({
      spacing: { before: 120, after: 60 },
      alignment: AlignmentType.CENTER,
      children: [
        new ImageRun({
          type: 'png',
          data: fs.readFileSync(abs),
          transformation: { width: IMG_W, height: h },
          altText: { title: caption, description: caption, name: file },
        }),
      ],
    }),
    new Paragraph({
      spacing: { after: 220 },
      alignment: AlignmentType.CENTER,
      children: [new TextRun({ text: `[화면] ${caption}`, size: 18, color: '64748B', italics: true })],
    }),
  ]
}

/** Minimal PNG IHDR reader so images keep their aspect ratio. */
function pngSize(file) {
  const buf = fs.readFileSync(file)
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) }
}

function infoTable(rows) {
  const col0 = 2600
  const col1 = CONTENT_DXA - col0
  return new Table({
    width: { size: CONTENT_DXA, type: WidthType.DXA },
    columnWidths: [col0, col1],
    rows: rows.map(([k, v], i) =>
      new TableRow({
        children: [
          new TableCell({
            borders,
            width: { size: col0, type: WidthType.DXA },
            shading: { fill: i === 0 ? 'D5E8F0' : 'F1F5F9', type: ShadingType.CLEAR },
            margins: { top: 80, bottom: 80, left: 120, right: 120 },
            children: [new Paragraph({ children: [new TextRun({ text: k, bold: true })] })],
          }),
          new TableCell({
            borders,
            width: { size: col1, type: WidthType.DXA },
            shading: { fill: i === 0 ? 'D5E8F0' : 'FFFFFF', type: ShadingType.CLEAR },
            margins: { top: 80, bottom: 80, left: 120, right: 120 },
            children: [new Paragraph({ children: [new TextRun({ text: v, bold: i === 0 })] })],
          }),
        ],
      }),
    ),
  })
}

function section(heading, paragraphs) {
  return [new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(heading)] }), ...paragraphs]
}

/** A boxed call-out for the one thing readers most often get wrong. */
function callout(title, text) {
  return new Table({
    width: { size: CONTENT_DXA, type: WidthType.DXA },
    columnWidths: [CONTENT_DXA],
    rows: [new TableRow({
      children: [new TableCell({
        borders: {
          top: { style: BorderStyle.SINGLE, size: 1, color: 'F59E0B' },
          bottom: { style: BorderStyle.SINGLE, size: 1, color: 'F59E0B' },
          left: { style: BorderStyle.SINGLE, size: 18, color: 'F59E0B' },
          right: { style: BorderStyle.SINGLE, size: 1, color: 'F59E0B' },
        },
        width: { size: CONTENT_DXA, type: WidthType.DXA },
        shading: { fill: 'FFFBEB', type: ShadingType.CLEAR },
        margins: { top: 140, bottom: 140, left: 200, right: 160 },
        children: [
          new Paragraph({ spacing: { after: 80 },
            children: [new TextRun({ text: title, bold: true, color: '92400E' })] }),
          new Paragraph({ children: [new TextRun({ text, color: '78350F' })] }),
        ],
      })],
    })],
  })
}

const children = [
  // ---------------- title page ----------------
  new Paragraph({ spacing: { before: 2400, after: 120 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '에이전트 판단 검토', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '운영자 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 시스템관리자(WMS_ADMIN)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '에이전트 제안을 검토·승인하는 창고관리자와 시스템관리자. 읽기만 하는 현장 작업자도 3장까지 참고'],
    ['다루는 화면', 'Agent Decisions (/agent/decisions)'],
    ['필요 권한',
      '제안 승인·반려: WAREHOUSE_MANAGER, WMS_ADMIN 전용 / ' +
      '판단·제안 이력과 디스패치 지연 신호 열람: 창고 스코프를 가진 모든 사용자 / ' +
      '인력 작업량 불균형 신호: WAREHOUSE_MANAGER, WMS_ADMIN, PROCESS_AGENT'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (agent-decisions-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 화면은 창고 운영을 자동으로 관찰하는 AI 에이전트가 "무엇을 보고, 무엇을 했고, 무엇을 ' +
    '하자고 제안하는지"를 사람이 읽고 결정하는 자리입니다. 승인 대기 중인 제안을 처리하는 방법, ' +
    '에이전트가 스스로 처리한 일을 사후에 확인하는 방법, 그리고 그 판단의 근거가 된 신호를 직접 ' +
    '들여다보는 방법을 순서대로 설명합니다.',
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('에이전트는 이 시스템 안에 없습니다')] }),
  body(
    '먼저 오해를 하나 풀고 시작하는 편이 좋습니다. WMS 안에서 AI가 돌고 있는 것이 아닙니다. ' +
    '에이전트는 ProcessGPT라는 별도 플랫폼에서 실행되고, 정해진 통로로만 이 WMS에 접근합니다. ' +
    'WMS가 하는 일은 세 가지뿐입니다.',
  ),
  bullet('에이전트가 볼 수 있는 신호를 내어 주는 것 — 인력 작업량 편차, 디스패치 지연 상황.'),
  bullet('에이전트가 혼자 할 수 있는 일과, 사람 허락이 필요한 일을 갈라 두는 것.'),
  bullet('에이전트가 무엇을 왜 했는지를 사람이 읽을 수 있게 남겨 두는 것 — 이 화면이 그 기록입니다.'),
  body(
    '그래서 이 화면에는 "에이전트 실행" 버튼도, "자동화 켜기" 스위치도 없습니다. 여기서 여러분이 ' +
    '하는 일은 검토와 결정뿐입니다.',
    { italics: true },
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('두 가지 기록이 한곳에 있습니다')] }),
  infoTable([
    ['상태', '뜻'],
    ['LOGGED', '에이전트가 **이미 스스로 처리한** 일과 그 이유입니다. 애초에 허락이 필요 없는 범위(예: 업무 오더 재시도)의 일이라 사후 보고에 해당합니다. 승인하거나 반려할 대상이 아니며, 상태가 바뀌지 않습니다.'],
    ['PROPOSED', '에이전트가 혼자 할 수 없어 **허락을 구하는** 제안입니다. 검토 대기 목록에 올라옵니다.'],
    ['CONFIRMED', '사람이 승인한 제안입니다. 누가 언제 승인했는지가 함께 남습니다.'],
    ['REJECTED', '사람이 반려한 제안입니다. 반려 사유가 함께 남습니다.'],
  ]),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('승인은 실행이 아닙니다')] }),
  callout(
    '이 매뉴얼에서 가장 중요한 한 문장',
    '제안을 승인해도 시스템은 그 조치를 자동으로 실행하지 않습니다. 승인은 "그렇게 해도 좋다"는 ' +
    '표시일 뿐이고, 실제 조치는 승인한 뒤에 사람이 해당 화면에서 직접 수행하거나 별도의 업무 ' +
    '프로세스가 수행합니다. 승인만 하고 자리를 뜨면 아무 일도 일어나지 않습니다.',
  ),
  new Paragraph({ spacing: { before: 200 }, children: [] }),
  body(
    '왜 이렇게 만들었는지도 알아 두면 판단에 도움이 됩니다. 승인 버튼이 곧바로 설비를 멈추거나 ' +
    '작업을 재배치하게 만들면, 결국 "사람이 한 번 눌렀다"는 형식만 남고 실질적으로는 AI가 창고를 ' +
    '움직이게 됩니다. 승인과 실행을 갈라 두면 승인 시점과 실행 시점이 각각 기록에 남고, 승인은 ' +
    '했지만 야간 작업 시간에 실행하는 것 같은 현실적인 운영도 가능해집니다.',
  ),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 1 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 검토 대기 제안 읽기')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴 WMS 그룹에서 Agent Decisions를 선택하면 이 화면이 열립니다.'),
    body(
      '맨 위 "검토 대기 제안"에 지금 결정을 기다리는 항목이 카드 형태로 쌓입니다. 옆의 숫자가 ' +
      '대기 건수입니다. 아래 화면에는 인력 재배치 제안과 설비 라우팅 제안 두 건이 올라와 있습니다.',
    ),
    ...shot('01-review-queue.png', '검토 대기 제안 두 건 — 각 카드에 판단 근거가 그대로 펼쳐져 있다'),
    body('카드 하나에서 확인할 것은 네 가지입니다.'),
    bullet('제안 유형 배지 — LABOR_REBALANCE(인력 재배치), EQUIPMENT_ROUTING_SUGGESTION(설비 라우팅 조정) 등.'),
    bullet('누가 언제 올렸는지 — 에이전트 계정 이름과 시각, 그리고 버전 번호.'),
    bullet('판단 근거 — 에이전트가 사람 말로 적어 둔 이유. 접혀 있지 않고 항상 펼쳐져 있습니다.'),
    bullet('"제안된 조치" 펼치기 — 무엇을 하자는 것인지 구조화된 내용. 필요하면 "판단 시점의 신호 스냅샷"도 펼쳐 그때 무엇을 보고 있었는지 확인할 수 있습니다.'),
  ]),
  ...section('근거를 항상 보이게 둔 이유', [
    body(
      '판단 근거를 접어 두면 아무도 펼쳐 보지 않고 유형만 보고 승인하게 됩니다. 그러면 검토라는 ' +
      '절차가 형식만 남습니다. 그래서 이 화면은 근거 문장을 카드 본문에 그대로 둡니다 — 제안을 ' +
      '보려면 이유를 읽을 수밖에 없게 만든 것입니다.',
    ),
    body(
      '근거가 이해되지 않거나 사실과 다르면 그것 자체가 반려 사유입니다. 근거를 확인할 수 없는 ' +
      '제안을 승인하면, 나중에 문제가 생겼을 때 기록에 남는 것은 에이전트의 판단이 아니라 ' +
      '승인한 사람의 이름입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 2 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 에이전트가 본 신호를 직접 확인하기')] }),
  ...section('하는 일', [
    body(
      '화면 맨 아래 "에이전트가 보는 신호"에는 에이전트가 호출하는 것과 완전히 같은 조회가 두 개 ' +
      '붙어 있습니다. 제안이 타당한지 남의 말로 판단하지 않고 직접 확인하라고 둔 것입니다.',
    ),
    ...shot('02-signals-the-agent-sees.png', '인력 작업량 불균형과 디스패치 지연 — 제안의 근거가 된 두 신호'),
  ]),
  ...section('인력 작업량 불균형', [
    body(
      '관찰 기간 안에 작업자별로 몇 건을 완료했는지, 그 값이 창고 평균에서 얼마나 벗어났는지를 ' +
      '보여줍니다. 평균에서 40% 이상 벗어나면 Imbalanced가 YES입니다.',
    ),
    bullet('Deviation은 부호가 있습니다. +80%는 그 사람에게 일이 몰렸다는 뜻이고, -80%는 손이 비어 있다는 뜻입니다. 재배치는 두 쪽을 함께 봐야 합니다.'),
    bullet('취소한 작업과 아직 진행 중인 작업은 어느 숫자에도 들어가지 않습니다.'),
    bullet('작업자가 한 명뿐이면 SINGLE_WORKER_NO_COMPARISON 표시가 붙습니다. "균형이 맞다"가 아니라 "비교할 대상이 없다"는 뜻입니다.'),
    body(
      '이 패널은 창고관리자·시스템관리자, 그리고 에이전트 계정에게만 보입니다. 현장 작업자에게는 ' +
      '패널 대신 안내 문구가 나옵니다 — 동료의 처리 건수는 개인 업무 기록이기 때문입니다.',
    ),
  ]),
  ...section('디스패치 지연', [
    body(
      '설비에 배차되지 못한 채 대기 중인 업무 오더와, 왜 못 나가고 있는지를 함께 보여줍니다. ' +
      '"지연 임계(분)"을 바꾸면 그 시간 이상 기다린 건만 남습니다.',
    ),
    body('Causes 열에 붙는 사유는 한 건에 여러 개가 동시에 붙을 수 있습니다.'),
    infoTable([
      ['사유', '뜻과 대처'],
      ['NO_EQUIPMENT_REGISTERED', '그 설비 유형·구역에 등록된 장비가 아예 없습니다. 설비 등록이 먼저입니다.'],
      ['NO_IDLE_EQUIPMENT', '지금 당장 받을 수 있는 장비가 없습니다. 대개 시간이 해결하지만, 오래 지속되면 장비가 부족한 것입니다.'],
      ['ALL_CANDIDATES_EXCLUDED', '후보 장비가 전부 사람 손으로 라우팅에서 제외되어 있습니다. 제외를 해제하지 않으면 영원히 나가지 못합니다.'],
      ['ALL_ROUTABLE_CANDIDATES_BOTTLENECKED / BOTTLENECK_AMONG_CANDIDATES', '받을 수 있는 장비가 병목으로 판정되어 있습니다. WCS Routing 화면에서 원인을 확인하세요.'],
      ['WAVE_NOT_RELEASED', '지연이 아닙니다. 웨이브가 아직 릴리스되지 않아 나갈 차례가 오지 않은 것입니다. 재시도해도 소용없고, WES Dispatch 화면에서 웨이브를 릴리스해야 합니다.'],
    ]),
    body(
      'Candidates 열의 "1 / 3"은 후보 장비 3대 중 지금 배차 가능한 것이 1대라는 뜻입니다.',
    ),
    body(
      '대기 시간은 업무 오더가 만들어진 시각이 아니라 **마지막 시도 시각**부터 셉니다. 재시도가 ' +
      '실패하면 그 시각이 갱신되므로, 이 숫자는 "또 재시도해 볼 만한가"에 대한 답입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 3 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 제안 승인하기')] }),
  ...section('하는 일', [
    body('근거와 신호를 확인했고 그대로 해도 좋다고 판단했다면 카드의 Confirm 버튼을 누릅니다.'),
    ...shot('03-proposal-confirmed.png', '승인 직후 — 대기 건수가 줄고, 이력에 CONFIRMED와 승인자가 남는다'),
    body('승인하면 세 가지가 일어납니다. 그리고 그 셋이 전부입니다.'),
    bullet('제안 상태가 CONFIRMED로 바뀌고, 승인한 사람과 승인 시각이 기록됩니다.'),
    bullet('그 카드가 검토 대기 목록에서 사라지고 아래 이력 표로 옮겨 갑니다.'),
    bullet('화면 위에 초록색 알림이 뜨는데, 그 문장 안에 "자동 실행되지 않습니다"라고 적혀 있습니다.'),
  ]),
  ...section('승인한 다음에 할 일', [
    body('승인은 시작이지 끝이 아닙니다. 제안 유형에 따라 다음 행동이 다릅니다.'),
    infoTable([
      ['제안 유형', '승인 후 사람이 해야 할 일'],
      ['LABOR_REBALANCE', '작업 재배치를 실행하는 기능은 이 시스템에 없습니다. 현장에 직접 지시하고, 옮겨 간 작업은 Labor 화면에서 각자 기록합니다.'],
      ['EQUIPMENT_ROUTING_SUGGESTION', 'WCS Routing 화면에서 해당 설비를 직접 라우팅 제외하거나 임계값을 조정합니다. 제안 카드의 "제안된 조치"에 어떤 기능을 쓰라고 적혀 있습니다.'],
    ]),
    callout(
      '승인했는데 아무 일도 안 일어난다면',
      '고장이 아닙니다. 설계가 그렇습니다. 위 표의 "승인 후 사람이 해야 할 일"을 아직 하지 않은 ' +
      '것입니다. 이력에서 그 제안의 "제안된 조치"를 다시 펼쳐 확인하세요.',
    ),
  ]),
  ...section('버전이 어긋났다는 오류가 나면', [
    body(
      '내가 화면을 열어 둔 사이에 다른 관리자가 같은 제안을 먼저 처리했다는 뜻입니다. Refresh를 ' +
      '누르고 이력에서 어떻게 처리되었는지 확인하세요. 같은 제안을 두 사람이 다르게 결정하는 ' +
      '사고를 막기 위한 정상 동작입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 4 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 제안 반려하기')] }),
  ...section('하는 일', [
    body(
      '제안이 타당하지 않다면 카드의 사유 입력란에 이유를 적고 Reject를 누릅니다. ' +
      '사유 없이 누르면 저장되지 않고 빨간 띠로 오류가 표시됩니다.',
    ),
    ...shot('04-reject-needs-a-reason.png', '사유 없이 반려를 시도하면 거부된다 — 반려 사유는 선택이 아니다'),
    ...shot('05-proposal-rejected.png', '사유와 함께 반려한 뒤 — 이력에 반려자와 사유가 함께 남는다'),
  ]),
  ...section('반려 사유를 필수로 만든 이유', [
    body(
      '이 시스템에는 에이전트가 스스로 배우는 장치가 없습니다. 잘못된 제안을 다시 올리지 않게 ' +
      '하려면 사람이 그 이유를 읽고 에이전트 쪽 설정을 고쳐야 하고, 반려 사유가 그 유일한 ' +
      '전달 통로입니다.',
    ),
    body(
      '"안 됨", "불필요" 같은 사유는 통과는 되지만 아무 정보도 전하지 못합니다. 무엇을 잘못 봤는지 ' +
      '한 줄이라도 적어 주세요 — 예: "해당 설비는 예정 정비 직후라 장애 1건은 정상 범위다."',
      { italics: true },
    ),
    body(
      '반려해도 아무것도 되돌려지지 않습니다. 애초에 제안이 무언가를 바꾼 적이 없기 때문입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 5 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 판단·제안 이력 보기')] }),
  ...section('하는 일', [
    body(
      '가운데 "판단·제안 이력" 표에 이 창고의 모든 기록이 최신순으로 쌓입니다. 상태와 제안 유형 ' +
      '두 가지로 걸러 볼 수 있습니다.',
    ),
    ...shot('06-decision-history.png', '판단·제안 이력 — LOGGED 자율 실행 기록과 처리된 제안이 한 표에 있다'),
    body(
      '표 위의 숫자 묶음(예: {"LOGGED": 1, "PROPOSED": 0, "CONFIRMED": 1, "REJECTED": 1})은 ' +
      '**필터와 상관없이 창고 전체**를 셉니다. 대기 건만 걸러 보고 있어도 뒤에 얼마나 많은 이력이 ' +
      '쌓여 있는지 알 수 있게 하려는 것입니다.',
    ),
  ]),
  ...section('LOGGED 항목 읽는 법', [
    body(
      'LOGGED 행은 에이전트가 허락을 구하지 않고 처리한 일입니다. 허락 없이 해도 되는 범위로 미리 ' +
      '정해 둔 일(대표적으로 업무 오더 재시도)이며, 대신 이유를 반드시 남기게 되어 있습니다.',
    ),
    body(
      '이 행들은 검토 대기 목록에 절대 올라오지 않고, 승인하거나 반려할 수도 없습니다. 이미 ' +
      '일어난 일에 대한 진술이기 때문입니다. 관리자가 할 일은 주기적으로 훑어보며 "에이전트가 ' +
      '혼자 해도 된다고 정해 둔 범위가 여전히 적절한가"를 확인하는 것입니다.',
    ),
    body(
      '내용이 마음에 들지 않는다면 그것은 개별 기록의 문제가 아니라 권한 설정의 문제입니다. ' +
      '시스템관리자에게 해당 작업을 승인 대상으로 바꿔 달라고 요청하세요.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 6 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 권한에 따라 화면이 어떻게 달라지나')] }),
  ...section('현장 작업자가 보는 화면', [
    body(
      '창고 스코프를 가진 사용자라면 누구나 이 화면을 열 수 있고, 에이전트의 판단 근거와 이력을 ' +
      '전부 읽을 수 있습니다. 에이전트가 무엇을 하고 있는지는 감출 정보가 아니기 때문입니다. ' +
      '다만 두 가지가 다릅니다.',
    ),
    ...shot('07-operator-read-only.png', '현장 작업자 화면 — 근거와 이력은 보이지만 승인·반려 버튼이 없다'),
    bullet('제안 카드에 Confirm/Reject 버튼이 없고 "검토 권한이 없습니다"라고만 표시됩니다.'),
    bullet('인력 작업량 불균형 패널이 통째로 없고, 대신 왜 볼 수 없는지 안내가 나옵니다 — 동료의 처리 건수를 비교하는 정보이기 때문입니다.'),
    bullet('디스패치 지연 패널은 그대로 보입니다. 개인 정보가 아니라 설비 상황이기 때문입니다.'),
  ]),
  ...section('버튼이 없는 것이 통제 장치는 아닙니다', [
    body(
      '버튼을 감춘 것은 화면의 예의이고, 실제 통제는 데이터베이스에 있습니다. 권한이 없는 사람이 ' +
      '다른 경로로 승인을 시도해도 거부됩니다. 에이전트 계정도 마찬가지입니다 — 자기가 만든 ' +
      '제안을 스스로 승인하려 하면 명시적으로 거부됩니다.',
    ),
    body(
      '이것이 이 계약 전체의 요점입니다. 제안을 만드는 쪽과 승인하는 쪽이 같으면 검토라는 절차가 ' +
      '존재하지 않는 것과 같습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- messages ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 빨간 띠로 표시되는 오류 메시지의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['INVALID: reason is required to reject a proposal',
      '반려 사유를 적지 않았습니다. 카드의 사유 입력란을 채우고 다시 누르세요.'],
    ['INVALID: agent decision … is not PROPOSED (status=CONFIRMED)',
      '이미 다른 사람이 처리한 제안입니다. Refresh를 눌러 이력에서 결과를 확인하세요.'],
    ['INVALID: agent decision … is not PROPOSED (status=LOGGED)',
      'LOGGED 기록을 승인하려 했습니다. 자율 실행 기록은 승인 대상이 아닙니다.'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 관리자가 먼저 이 제안을 처리했습니다. Refresh 후 확인하세요.'],
    ['FORBIDDEN: role cannot review agent proposals',
      '현재 역할에는 검토 권한이 없습니다. 오른쪽 위 역할 배지를 확인하세요.'],
    ['FORBIDDEN: PROCESS_AGENT may create proposals but not confirm or reject them',
      '에이전트 계정으로 승인·반려를 시도했습니다. 사람이 로그인해서 처리해야 합니다.'],
    ['FORBIDDEN: role cannot read warehouse-wide labor balance signals',
      '인력 작업량 신호는 창고관리자·시스템관리자·에이전트만 볼 수 있습니다.'],
    ['FORBIDDEN: no warehouse scope for agent decision …',
      '내 담당 창고가 아닌 곳의 제안입니다. 화면 위 창고 표시를 확인하세요.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/agent-decisions-flow.spec.ts)를 ' +
    '로컬 환경에서 실행하며 캡처한 것입니다. 화면이 매뉴얼과 다르게 보인다면 앱 버전이 다른 것이므로 ' +
    '관리자에게 문의하세요.',
    { size: 20, color: '64748B', italics: true },
  ),
]

const doc = new Document({
  styles: {
    default: { document: { run: { font: 'Arial', size: 22 } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 32, bold: true, font: 'Arial', color: '1B2430' },
        paragraph: { spacing: { before: 240, after: 240 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 26, bold: true, font: 'Arial', color: '2563EB' },
        paragraph: { spacing: { before: 200, after: 140 }, outlineLevel: 1 } },
    ],
  },
  numbering: {
    config: [{
      reference: 'bullets',
      levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 720, hanging: 360 } } } }],
    }],
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },
        margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 },
      },
    },
    headers: {
      default: new Header({ children: [new Paragraph({
        alignment: AlignmentType.RIGHT,
        children: [new TextRun({ text: '에이전트 판단 검토 · 운영자 매뉴얼', size: 18, color: '94A3B8' })],
      })] }),
    },
    footers: {
      default: new Footer({ children: [new Paragraph({
        alignment: AlignmentType.CENTER,
        children: [new TextRun({ text: '', size: 18, color: '94A3B8' }),
                   new TextRun({ children: [PageNumber.CURRENT], size: 18, color: '94A3B8' })],
      })] }),
    },
    children,
  }],
})

const buffer = await Packer.toBuffer(doc)
fs.writeFileSync(OUT, buffer)
console.log('wrote', OUT, (buffer.length / 1024).toFixed(0) + 'KB')
