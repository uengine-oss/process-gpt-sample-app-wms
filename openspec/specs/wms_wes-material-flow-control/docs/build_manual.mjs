// Builds the WES 자재 흐름 제어 운영자 매뉴얼 (.docx) from the screenshots captured
// by frontend/playwright/e2e/wes-dispatch-flow.spec.ts.
//
//   npm install -g docx      # or a local `npm install docx`
//   node build_manual.mjs
//
// Same generator shape as openspec/specs/wms_wcs-equipment-control/docs/build_manual.mjs
// so the two manuals stay visually consistent. Every screenshot in this manual
// is a real frame from a passing Playwright run against a live local Supabase —
// nothing here is mocked up.

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
const OUT = path.resolve(HERE, 'wes-material-flow-control-operator-manual.docx')

// US Letter, 1" margins -> 9360 DXA of content width.
const CONTENT_DXA = 9360
// Screenshots are 1280x~720-900 CSS px; scale to fit the text column (6.5in).
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

const children = [
  // ---------------- title page ----------------
  new Paragraph({ spacing: { before: 2400, after: 120 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WES 자재 흐름 제어', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '디스패치 웨이브 운영 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 설비운영자(WCS_OPERATOR)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '창고관리자, 설비운영자'],
    ['다루는 화면', 'WES Dispatch (/wes/dispatch)'],
    ['필요 권한', 'WAREHOUSE_MANAGER, WCS_OPERATOR, PROCESS_AGENT (그 외 역할은 조회만 가능)'],
    ['선행 준비', '설비가 WCS Equipment 화면에 등록되어 있고 상태가 IDLE일 것 (별도 매뉴얼: WCS 자동화 설비 제어)'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (wes-dispatch-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 매뉴얼은 "창고에서 해야 할 일"과 "그 일을 실제로 수행하는 설비" 사이를 잇는 WES Dispatch ' +
    '화면의 사용법을 설명합니다. 입고된 물건을 적치해야 할 때, 그 일을 업무 오더로 등록하고, ' +
    '언제 설비를 움직일지 정하고, 설비가 일을 마쳤는지 확인하는 절차를 순서대로 다룹니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('업무 오더와 웨이브')] }),
  body(
    '두 가지 개념만 이해하면 이 화면은 전부입니다.',
  ),
  bullet(
    '업무 오더(Work Order) — "이 입고 건을 ZONE-C로 옮겨라" 같은 한 건의 지시입니다. ' +
    '어떤 종류의 설비가(Equipment Type), 어느 구역에서(Target Zone), 무슨 동작을(Command) 해야 하는지를 담습니다.',
  ),
  bullet(
    '디스패치 웨이브(Dispatch Wave) — 업무 오더를 모아 두었다가 한꺼번에 내보내는 묶음입니다. ' +
    '웨이브는 OPEN(모으는 중)과 RELEASED(내보냄) 두 상태만 가집니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('WAVE와 WAVELESS — 언제 내보낼 것인가')] }),
  infoTable([
    ['이행 전략', '언제 쓰는가'],
    ['WAVE', '업무 오더를 웨이브에 모아 두었다가, 준비가 되면 한 번에 내보냅니다. 작업을 시간대별로 묶어 처리할 때 씁니다. 릴리즈 전까지 업무 오더는 QUEUED 상태로 대기합니다.'],
    ['WAVELESS', '등록하는 순간 곧바로 설비를 찾아 명령을 보냅니다. 급한 건이나 상시 흐름 처리에 씁니다.'],
  ]),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('설비는 시스템이 고릅니다')] }),
  body(
    '어떤 설비에 일을 시킬지는 운영자가 지정하지 않습니다. 시스템이 다음 순서로 고릅니다.',
  ),
  bullet('업무 오더에 적힌 설비 종류와 구역이 일치하고, 상태가 IDLE(대기)인 설비만 후보가 됩니다.'),
  bullet('이미 처리 중인 명령이 있는 설비는 후보에서 빠집니다.'),
  bullet('후보가 여럿이면 최근에 처리한 건수가 가장 적은 설비를 고릅니다 — 한쪽으로 일이 쏠리지 않게 하는 단순 분산 규칙입니다.'),
  body(
    '조건에 맞는 설비가 하나도 없으면 오류가 아닙니다. 업무 오더는 QUEUED로 남고 ' +
    '"NO_EQUIPMENT_AVAILABLE" 안내가 표시됩니다. 설비가 비는 대로 Retry 버튼을 누르면 됩니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('업무 오더 상태 읽는 법')] }),
  infoTable([
    ['상태', '의미'],
    ['QUEUED', '등록되었으나 아직 설비에 나가지 않음. 웨이브 릴리즈를 기다리거나, 가용 설비를 기다리는 중입니다.'],
    ['DISPATCHED', '설비에 명령이 전달되어 진행 중입니다.'],
    ['COMPLETED', '설비가 작업을 끝냈다고 보고했습니다. 운영자가 누르는 버튼이 아니라 자동으로 바뀝니다.'],
    ['FAILED', '설비가 작업에 실패했다고 보고했거나 설비 장애로 명령이 종결되었습니다.'],
    ['CANCELLED', '운영자가 취소했습니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- steps ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 화면 열기')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴에서 WES Dispatch를 선택합니다. 처음에는 아무것도 없는 빈 보드가 나옵니다.'),
    body(
      '화면은 위에서부터 세 부분입니다. ① 디스패치 웨이브 카드, ② 업무 오더 등록 카드, ' +
      '③ 업무 오더 목록. 오른쪽 위 역할 배지가 WAREHOUSE_MANAGER, WCS_OPERATOR, PROCESS_AGENT 중 ' +
      '하나여야 ①②가 보입니다.',
    ),
    ...shot('01-empty-board.png', 'WES Dispatch 첫 화면 — 웨이브도 업무 오더도 없는 상태'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 디스패치 웨이브 개설')] }),
  ...section('하는 일', [
    body(
      '"디스패치 웨이브" 카드에서 Open Wave 버튼을 누릅니다. 입력할 값은 없습니다 — 웨이브는 ' +
      '"지금부터 모을 묶음"을 여는 것뿐입니다.',
    ),
    body(
      '표에 새 웨이브가 나타나고 상태는 OPEN, Version은 1입니다. 한 창고에 OPEN 웨이브를 여러 개 ' +
      '동시에 열어 둘 수 있습니다(예: 오전 출고분과 오후 출고분).',
    ),
    ...shot('02-wave-opened.png', '웨이브 개설 직후 — 상태 OPEN, Version 1, Work Orders 0'),
    body(
      'Version 숫자는 여러 사람이 같은 웨이브를 동시에 조작하다가 서로의 작업을 덮어쓰는 사고를 ' +
      '막는 안전장치입니다. 웨이브가 바뀔 때마다 1씩 올라갑니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 업무 오더 등록')] }),
  ...section('하는 일', [
    body('"업무 오더 등록" 카드에 다음을 채웁니다.'),
    bullet('Receipt — 이 작업이 처리할 입고 건을 고릅니다. 목록에는 이 창고의 입고 건이 최신순으로 나옵니다.'),
    bullet('Equipment Type — 어떤 종류의 설비가 처리할지 고릅니다 (SRM / CONVEYOR / SORTER / AGV / AMR / ROBOT_CELL).'),
    bullet('Target Zone — 그 설비가 있어야 할 구역입니다 (화면 예시는 ZONE-WES). 비워 두면 창고 안 모든 구역이 후보가 됩니다.'),
    bullet('Command — 설비에 보낼 동작입니다 (예: MOVE).'),
    bullet('to_zone — 이동 목적지처럼 명령에 딸린 값입니다 (예: ZONE-C).'),
    bullet('Dispatch Mode — WAVE(모아 두었다 내보냄) 또는 WAVELESS(즉시 내보냄).'),
    bullet('Wave — WAVE를 골랐을 때만 나타납니다. 어느 OPEN 웨이브에 담을지 고릅니다.'),
    body('Create Work Order를 누르면 업무 오더가 등록됩니다.'),
    ...shot('03-work-orders-queued.png', '같은 웨이브에 업무 오더 3건을 등록한 상태 — 모두 QUEUED, Equipment Command 열은 비어 있음'),
  ]),
  ...section('WAVE 모드에서는 아직 설비가 움직이지 않습니다', [
    body(
      '위 화면에서 세 건 모두 상태가 QUEUED이고 Equipment Command 열이 "—"인 점을 확인하세요. ' +
      'WAVE 모드로 등록한 업무 오더는 웨이브를 릴리즈하기 전까지 설비로 나가지 않습니다. ' +
      '이 시점에는 아직 취소하거나 내용을 다시 검토할 여유가 있습니다.',
    ),
    body(
      'WAVELESS로 등록했다면 이 단계에서 곧바로 DISPATCHED가 되고 Equipment Command 열에 ' +
      '설비 코드와 명령 상태가 채워집니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 웨이브 릴리즈')] }),
  ...section('하는 일', [
    body(
      '웨이브 표에서 해당 웨이브 행의 Release Wave 버튼을 누릅니다. 웨이브 상태가 RELEASED로 바뀌고, ' +
      '그 웨이브에 담긴 QUEUED 업무 오더를 등록 순서대로 하나씩 설비에 내보냅니다.',
    ),
    body(
      '예시에서는 대기 중인 AGV가 두 대뿐인데 업무 오더는 세 건이었습니다. 결과는 다음과 같습니다.',
    ),
    bullet('두 건은 DISPATCHED가 되고, Equipment Command 열에 서로 다른 설비 코드가 찍힙니다 — 한 대에 몰아주지 않고 나눠 배분한 것입니다.'),
    bullet('남은 한 건은 QUEUED로 남고, 화면 위에 "NO_EQUIPMENT_AVAILABLE: 1 work order(s) stay QUEUED" 안내가 표시됩니다.'),
    ...shot('04-wave-released.png', '릴리즈 결과 — 2건 DISPATCHED(설비 2대에 분산), 1건 QUEUED + 설비 부족 안내'),
    body(
      '이 안내는 오류가 아닙니다. "설비가 모자라서 지금은 못 내보냈다"는 정상적인 상황 보고이며, ' +
      '남은 업무 오더는 그대로 살아 있습니다. 이미 릴리즈한 웨이브는 다시 릴리즈할 수 없습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 완료 확인 (설비가 자동으로 알려줍니다)')] }),
  ...section('무슨 일이 일어나는가', [
    body(
      '설비는 명령을 접수하고, 수행하고, 끝나면 그 결과를 WMS에 되돌려 보고합니다. 이 보고는 ' +
      'WCS 게이트웨이(설비 쪽 시스템)가 하는 일이며 운영자가 누를 버튼은 없습니다.',
    ),
    body(
      '설비 명령이 완료로 보고되면, 그 명령에 묶인 업무 오더가 자동으로 COMPLETED로 바뀝니다. ' +
      '화면을 새로고침하면 Status 열이 DISPATCHED에서 COMPLETED로, Equipment Command 열의 명령 ' +
      '상태도 COMPLETED로 바뀐 것이 보입니다.',
    ),
    ...shot('05-work-order-completed.png', '설비 완료 보고가 업무 오더에 자동 반영됨 — 첫 번째 행이 COMPLETED'),
    body(
      '중요한 경계 하나: 업무 오더가 COMPLETED가 되어도 그 업무 오더가 가리키는 입고(Receipt) 건의 ' +
      '상태는 이 화면이 바꾸지 않습니다. 입고 건의 다음 단계 처리는 입고/검수 화면과 프로세스 ' +
      '자동화가 담당합니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 남은 업무 오더 재시도')] }),
  ...section('하는 일', [
    body(
      '설비 한 대가 일을 마쳐 다시 대기(IDLE) 상태가 되면, 설비가 없어 QUEUED로 남아 있던 업무 오더를 ' +
      '내보낼 수 있습니다. 그 행의 Retry 버튼을 누르세요.',
    ),
    body(
      '성공하면 상태가 DISPATCHED로 바뀌고 Equipment Command 열에 방금 비었던 설비의 코드가 찍힙니다. ' +
      '이번에도 설비가 없으면 오류 없이 QUEUED로 남고 같은 안내가 다시 표시됩니다 — 몇 번이든 다시 ' +
      '눌러도 됩니다.',
    ),
    ...shot('06-retry-dispatched.png', 'Retry 성공 — 대기 중이던 업무 오더가 DISPATCHED로 전환'),
    body(
      'Retry 버튼은 QUEUED 상태에서만 나타납니다. 또한 아직 릴리즈하지 않은 OPEN 웨이브에 속한 ' +
      '업무 오더에는 나타나지 않습니다 — 그건 Retry가 아니라 웨이브 릴리즈로 처리해야 합니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('7. 실패했을 때')] }),
  ...section('무슨 일이 일어나는가', [
    body(
      '설비가 장애물 감지 등으로 작업을 끝내지 못하면 실패를 보고합니다. 그러면 그 명령에 묶인 ' +
      '업무 오더도 자동으로 FAILED로 바뀝니다. 설비 장애(FAULT)가 발생해 진행 중이던 명령이 ' +
      '일괄 종결되는 경우에도 마찬가지입니다.',
    ),
    ...shot('07-work-order-failed.png', '설비 실패 보고가 업무 오더에 반영됨 — 해당 행이 FAILED'),
    body(
      'FAILED는 종결 상태입니다. 되살릴 수 없으므로, 같은 일을 다시 시키려면 업무 오더를 새로 ' +
      '등록하세요. 설비 자체에 장애가 있었다면 WCS Monitor 화면에서 장애를 먼저 해소해야 합니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('8. 업무 오더 취소')] }),
  ...section('하는 일', [
    body(
      '아직 끝나지 않은 업무 오더(QUEUED 또는 DISPATCHED)는 Cancel 버튼으로 취소할 수 있습니다. ' +
      '통로가 막혔거나 작업 계획이 바뀐 경우에 사용합니다.',
    ),
    body(
      '이미 설비에 명령이 나간 DISPATCHED 상태를 취소하면, 그 설비 명령도 함께 취소됩니다. ' +
      '화면 위에 "연결된 설비 명령 …도 함께 취소" 안내가 뜨고, Equipment Command 열의 명령 상태도 ' +
      'CANCELLED로 바뀝니다. 설비는 다시 대기 상태로 돌아가 다음 일을 받을 수 있습니다.',
    ),
    ...shot('08-work-order-cancelled.png', '취소 결과 — 업무 오더와 연결된 설비 명령이 함께 CANCELLED'),
    body(
      '이미 COMPLETED, FAILED, CANCELLED로 끝난 업무 오더는 취소할 수 없습니다. Cancel 버튼 대신 ' +
      '"종결" 표시만 나옵니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('9. 권한이 없는 역할로 보면')] }),
  ...section('조회는 되고 조작은 안 됩니다', [
    body(
      '웨이브 개설과 업무 오더 등록·재시도·취소는 창고관리자(WAREHOUSE_MANAGER), ' +
      '설비운영자(WCS_OPERATOR), 프로세스 자동화(PROCESS_AGENT)만 할 수 있습니다.',
    ),
    body(
      '그 외 역할로 로그인하면 두 개의 입력 카드와 행별 Actions 열이 아예 표시되지 않고, ' +
      '업무 오더 현황만 조회할 수 있습니다. 다른 창고·다른 회사의 업무 오더는 목록에 나오지 않습니다.',
    ),
    ...shot('09-read-only-role.png', '조작 권한이 없는 역할 — 등록/릴리즈 카드가 보이지 않고 현황만 조회됨'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- troubleshooting ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 표시되는 안내(파란 띠)와 오류(빨간 띠)의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['NO_EQUIPMENT_AVAILABLE',
      '오류가 아닙니다. 조건에 맞는 대기 상태 설비가 없어 업무 오더가 QUEUED로 남았습니다. 설비가 비면 Retry를 누르세요. 계속 반복된다면 Target Zone과 Equipment Type이 실제 설비와 맞는지 확인하세요.'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 사람이나 설비가 먼저 상태를 바꿨습니다. 화면을 새로고침한 뒤 다시 시도하세요. 덮어쓰기 사고를 막기 위한 정상 동작입니다.'],
    ['FORBIDDEN: role cannot …',
      '현재 로그인한 역할에는 이 작업 권한이 없습니다. 오른쪽 위 역할 배지를 확인하고 권한이 있는 담당자에게 요청하세요.'],
    ['INVALID: dispatch wave … is not OPEN',
      '이미 릴리즈된 웨이브에 업무 오더를 넣으려 했거나, 같은 웨이브를 두 번 릴리즈하려 했습니다. 새 웨이브를 여세요.'],
    ['INVALID: work order … is not QUEUED',
      '이미 나갔거나 끝난 업무 오더를 재시도하려 했습니다. 목록을 새로고침해 현재 상태를 확인하세요.'],
    ['INVALID: work order … is already terminal',
      'COMPLETED / FAILED / CANCELLED로 끝난 업무 오더는 취소할 수 없습니다.'],
    ['연결할 입고(receipt)를 선택하세요',
      'Receipt 목록이 비어 있으면 이 창고에 입고 건이 아직 없습니다. 입고(Receiving) 화면에서 먼저 입고 건을 만드세요.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/wes-dispatch-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: 'WES 자재 흐름 제어 · 디스패치 웨이브 운영 매뉴얼', size: 18, color: '94A3B8' })],
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
