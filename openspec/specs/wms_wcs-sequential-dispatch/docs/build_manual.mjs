// Builds the 서열 출고/지능형 적재 운영자 매뉴얼 (.docx) from the screenshots
// captured by frontend/playwright/e2e/wcs-sequential-dispatch-flow.spec.ts.
//
//   npm install -g docx      # or a local `npm install docx`
//   node build_manual.mjs
//
// Same generator shape as the four build_manual.mjs before it
// (wms_wcs-equipment-control, wms_wes-material-flow-control,
// wms_wcs-sortation-logic, wms_wcs-bottleneck-routing) so the five manuals stay
// visually consistent. Every screenshot in this manual is a real frame from a
// passing Playwright run against a live local Supabase — nothing here is
// mocked up.

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
const OUT = path.resolve(HERE, 'wcs-sequential-dispatch-operator-manual.docx')

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
    children: [new TextRun({ text: '서열 출고 · 지능형 적재', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '출고 단위 등록 · 서열 배정 · 혼합 팔레타이징 운영 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 설비운영자(WCS_OPERATOR)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '창고관리자, 설비운영자'],
    ['다루는 화면', 'WCS Sequencing (/wcs/sequential-dispatch)'],
    ['필요 권한',
      '출고 단위 등록: WMS_ADMIN, WAREHOUSE_MANAGER / 서열 배정·취소: 여기에 WCS_OPERATOR 추가 / ' +
      'PALLETIZE·WRAP 명령: WAREHOUSE_MANAGER, WCS_OPERATOR (WMS_ADMIN 불가) — 그 외 역할은 조회만'],
    ['선행 준비',
      '로봇 셀(ROBOT_CELL)이 WCS Equipment 화면에 등록되어 IDLE 상태일 것 (별도 매뉴얼: WCS 자동화 설비 제어)'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (wcs-sequential-dispatch-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '매장으로 나갈 물건을 "어떤 순서로, 어느 팔레트에" 실을지 정하고, 그 팔레트를 로봇 셀이 ' +
    '쌓게 하는 화면입니다. 이 매뉴얼은 출고 단위를 등록하는 것부터 완성된 팔레트에 무엇이 ' +
    '실렸는지 확인하는 것까지를 순서대로 설명합니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('이 화면이 하지 않는 일')] }),
  body(
    '먼저 오해를 없애는 것이 중요합니다. 이 화면은 재고를 확인하거나 잡아 두지 않습니다. ' +
    '"출고 단위"를 등록해도 창고 재고가 줄지 않고, 어딘가에 예약되지도 않습니다. 피킹 지시가 ' +
    '나가지도 않고, 출하가 확정되지도 않습니다.',
    { italics: true },
  ),
  body(
    '이 화면이 다루는 것은 오직 하나 — "이미 나가기로 정해진 것들을 어떤 순서로 어느 팔레트에 ' +
    '쌓을 것인가"입니다. 그래서 여기서 말하는 출고 단위는 "매장, 상품, 수량"만 있는 아주 얇은 ' +
    '기록입니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('세 가지 개념')] }),
  infoTable([
    ['개념', '뜻'],
    ['출고 단위 (Outbound Order)',
      '"어느 매장으로 어떤 상품을 몇 개" 한 줄. 상품 하나당 한 줄이며, 여러 상품을 한 주문으로 ' +
      '묶는 개념은 없습니다. 같은 매장으로 여러 상품을 보내려면 여러 줄을 등록하고, 그것들을 ' +
      '한 팔레트로 묶는 것은 아래 "목표 팔레트"가 합니다.'],
    ['서열 배정 (Sequence)',
      '출고 단위 하나에 "웨이브 안에서 몇 번째"(서열 위치)와 "어느 팔레트에"(목표 팔레트)를 ' +
      '붙이는 일입니다. 서열 위치는 같은 웨이브 안에서 겹칠 수 없습니다.'],
    ['팔레트 (Target Pallet)',
      '같은 팔레트 코드를 붙인 항목들은 나중에 **한 번의 명령**으로 같은 로봇 셀에 함께 ' +
      '내려갑니다. 이것이 "혼합 팔레타이징"입니다.'],
  ]),
  body(
    '중요한 것 하나 — 서열 위치와 팔레트 배분을 시스템이 계산해 주지 않습니다. 매장 진열 순서나 ' +
    '배송 순서를 아는 사람은 운영자이고, 화면은 그 판단을 받아 적고 규칙에 맞는지 검사할 뿐입니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('중량·용적은 "선언값"입니다')] }),
  body(
    '상품마다 무게와 부피가 마스터에 저장돼 있지 않기 때문에, 출고 단위를 등록할 때 운영자가 ' +
    '직접 적습니다. 이 선언값의 합계가 팔레트 상한 검사의 기준이 됩니다. 나중에 로봇 셀이 실제로 ' +
    '계근한 값과 나란히 보이므로, 둘이 크게 어긋나면 선언값 관리가 부실하다는 신호로 읽으면 ' +
    '됩니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('작업 순서')] }),
  infoTable([
    ['순서', '무엇을'],
    ['1. 웨이브 열기', '이 매뉴얼 1장. 서열은 웨이브 안에서만 의미가 있습니다.'],
    ['2. 출고 단위 등록', '이 매뉴얼 2장. 매장·상품·수량·선언 중량/용적을 적습니다.'],
    ['3. 서열 배정', '이 매뉴얼 3장. 순서와 목표 팔레트를 정합니다.'],
    ['4. 팔레타이징 지시', '이 매뉴얼 4~5장. 팔레트 하나를 로봇 셀 하나에 통째로 보냅니다.'],
    ['5. 결과 확인', '이 매뉴얼 6~7장. 무엇이 실렸고 무엇이 빠졌는지 봅니다.'],
    ['6. 포장', '이 매뉴얼 8장. 완성된 팔레트에 스트레치 필름을 감습니다.'],
    ['7. 되돌리기', '이 매뉴얼 10장. 잘못 묶었으면 취소하고 다시 배정합니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 1 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 화면 열기와 웨이브 만들기')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴에서 WCS Sequencing을 선택합니다. 처음에는 아무것도 없는 빈 화면입니다.'),
    ...shot('01-empty-board.png', '아직 웨이브도 출고 단위도 없는 초기 화면'),
    body(
      '맨 위 "디스패치 웨이브" 카드에서 Open Wave를 누릅니다. 웨이브는 "이번 묶음"을 뜻하는 ' +
      '상자라고 생각하면 됩니다 — 서열 번호 1, 2, 3은 그 상자 안에서만 유일하면 됩니다.',
    ),
    ...shot('02-wave-opened.png', 'OPEN 상태 웨이브가 하나 생겼습니다'),
  ]),
  ...section('알아 둘 점', [
    bullet('웨이브는 여러 개를 동시에 열어 둘 수 있습니다. 서열 번호는 웨이브마다 따로 셉니다.'),
    bullet('RELEASED(릴리즈됨) 상태가 된 웨이브에는 새 서열을 배정할 수 없습니다. 새 웨이브를 여세요.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 2 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 출고 단위 등록하기')] }),
  ...section('하는 일', [
    body(
      '"출고 단위 등록" 카드에 매장 코드, 상품, 수량, 그리고 선언 중량·용적을 적고 ' +
      'Create Outbound Order를 누릅니다. Order Number는 외부 시스템 번호를 적어 두는 칸이며 ' +
      '비워 둬도 됩니다.',
    ),
    ...shot('03-outbound-orders-created.png', '매장 A로 갈 두 건과 매장 B로 갈 무거운 한 건을 등록했습니다'),
    body('등록 직후 상태는 항상 OPEN입니다 — "아직 순서를 안 정했다"는 뜻입니다.'),
  ]),
  ...section('거부되는 경우', [
    bullet('수량이 0 이하이면 등록되지 않습니다.'),
    bullet('매장 코드를 비워 두면 등록되지 않습니다.'),
    bullet('선언 중량·용적에 음수를 넣으면 등록되지 않습니다(비워 두는 것은 괜찮습니다).'),
  ]),
  ...section('권한', [
    body(
      '출고 단위를 만드는 것은 "무엇을 내보낼지"를 정하는 상위 판단이라, 설비운영자' +
      '(WCS_OPERATOR)에게는 이 카드가 보이지 않습니다. 창고관리자와 관리자만 등록할 수 있습니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 3 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 서열 배정하기')] }),
  ...section('하는 일', [
    body(
      '"서열 배정" 카드에서 OPEN 상태 출고 단위를 하나 고르고, 웨이브·서열 위치·목표 팔레트를 ' +
      '정한 뒤 Assign Sequence를 누릅니다. 서열 위치는 다음 배정을 위해 자동으로 1 증가합니다.',
    ),
    ...shot('04-sequences-assigned.png', '1·2번은 같은 팔레트, 3번은 다른 팔레트로 배정했습니다'),
    body(
      '배정되면 출고 단위 상태가 OPEN에서 SEQUENCED로 바뀌고, 아래 "팔레트 현황" 표에 팔레트별 ' +
      '건수와 선언 중량 합계가 나타납니다. 위 화면에서 PLT-SEQ-E2E-1의 선언 중량 10.2kg은 ' +
      '4.2kg과 6.0kg을 더한 값입니다.',
    ),
  ]),
  ...section('같은 번호는 두 번 쓸 수 없습니다', [
    body(
      '한 웨이브 안에서 서열 위치는 유일해야 합니다. 이미 쓴 번호를 다시 배정하려고 하면 빨간 띠로 ' +
      '거부됩니다.',
    ),
    ...shot('05-duplicate-position-rejected.png', '이미 1번이 있는 웨이브에 다시 1번을 배정하려다 거부됨'),
    body(
      '취소한 배정이 쓰던 번호는 다시 쓸 수 있습니다 — 취소는 자리를 비워 줍니다(10장 참고).',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 4 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 중량 상한 — 보내기 전에 걸러집니다')] }),
  ...section('하는 일', [
    body(
      '"팔레타이징 / 스트레치 포장 명령" 카드에는 Max Weight(kg)과 Max Volume(L) 칸이 있습니다. ' +
      '값을 넣으면, 그 팔레트에 묶인 항목들의 **선언값 합계**가 상한을 넘을 때 명령 자체가 나가지 ' +
      '않습니다.',
    ),
    ...shot('06-weight-ceiling-blocks-dispatch.png', '240kg짜리 팔레트에 100kg 상한을 걸어 거부된 모습'),
    body(
      '거부되면 아무것도 바뀌지 않습니다 — 명령도 안 생기고, 서열 배정도 그대로 QUEUED로 ' +
      '남습니다. 상한을 올리거나, 팔레트를 나누거나, 선언값을 고친 뒤 다시 시도하세요.',
    ),
  ]),
  ...section('상한은 두 번 확인됩니다', [
    infoTable([
      ['시점', '무엇을 잡아내는가'],
      ['보내기 전 (이 장)',
        '선언값 합계 vs 상한. "애초에 계획을 잘못 짰다"를 잡습니다. 명령이 아예 만들어지지 ' +
        '않습니다.'],
      ['쌓은 뒤 (7장)',
        '로봇 셀이 실제로 잰 무게 vs 상한. "계획은 맞았는데 실물이 달랐다"를 잡습니다. 명령은 ' +
        '실패로 끝나고 관련 항목이 모두 실패 처리됩니다.'],
    ]),
    body(
      '둘 다 있는 이유는 실패 원인이 다르기 때문입니다. 앞의 것은 서류 문제, 뒤의 것은 현물 ' +
      '문제입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 5 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 팔레타이징 명령 보내기')] }),
  ...section('하는 일', [
    body(
      'Robot Cell, Wave, Target Pallet을 고르고 Dispatch PALLETIZE를 누릅니다. 그 팔레트에 묶인 ' +
      '대기(QUEUED) 항목이 **전부** 서열 순서대로 하나의 명령에 담겨 나갑니다.',
    ),
    ...shot('07-palletize-dispatched.png', '두 건이 한 번의 PALLETIZE 명령으로 나가 둘 다 DISPATCHED가 됨'),
    body(
      '알림 띠에 "2건"이라고 나오고, 서열 배정 표의 두 줄이 동시에 DISPATCHED로 바뀌며 같은 ' +
      '설비 명령을 가리킵니다. 이것이 이 화면의 핵심입니다 — 여러 출고 단위, 명령 하나.',
    ),
  ]),
  ...section('한 팔레트는 한 셀에서만 쌓습니다', [
    body(
      '물리적으로 팔레트 하나는 처음부터 끝까지 같은 로봇 셀에서 쌓여야 합니다. 그래서 다른 ' +
      '화면들과 달리 대상 셀을 시스템이 골라 주지 않고 운영자가 지정하며, 이미 다른 팔레트를 ' +
      '쌓고 있는 셀에는 새 팔레트를 보낼 수 없습니다.',
    ),
    ...shot('08-one-cell-one-pallet.png', '작업 중인 셀에 다른 팔레트를 보내려다 거부된 모습'),
    bullet('로봇 셀(ROBOT_CELL)이 아닌 설비 — 예를 들어 AGV — 에는 팔레타이징 명령을 보낼 수 없습니다.'),
    bullet('그 팔레트에 대기 중인 항목이 하나도 없으면 보낼 것이 없으므로 거부됩니다.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 6 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 결과를 기다리는 동안')] }),
  ...section('하는 일', [
    body(
      '명령을 보낸 뒤 로봇 셀이 답을 주기 전까지, 화면 맨 아래 "팔레트 매니페스트"에는 그 팔레트가 ' +
      '"결과 미보고"로 표시됩니다. 이것은 오류가 아니라 정상 상태입니다.',
    ),
    ...shot('09-manifest-before-report.png', '아직 답이 없는 팔레트 — 계획 건수만 보입니다'),
    body(
      '"계획 2건"처럼 몇 개를 보냈는지는 보이므로, 응답이 늦는지 아니면 애초에 아무것도 안 ' +
      '보냈는지를 구분할 수 있습니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 7 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('7. 결과 반영 — 항목별로 다르게 끝납니다')] }),
  ...section('하는 일', [
    body(
      '로봇 셀이 결과를 보고하면 화면을 새로고침합니다. 여기서 중요한 것은, 명령은 하나였지만 ' +
      '**결과는 항목별로 다를 수 있다**는 점입니다.',
    ),
    ...shot('10-per-item-propagation.png', '한 번의 보고로 1번은 COMPLETED, 2번은 FAILED가 됨'),
    body(
      '위 화면은 셀이 "부분 적재(PARTIAL)"로 답한 경우입니다 — 1번은 실었고 2번은 무게 때문에 ' +
      '뺐다는 뜻입니다. 아무도 손대지 않았는데 두 줄이 각각 다른 상태로 바뀌었고, 팔레트 현황의 ' +
      'Completed/Failed 숫자도 1과 1로 나뉘었습니다.',
    ),
  ]),
  ...section('결과 값 읽는 법', [
    infoTable([
      ['셀이 답한 값', '뜻과 결과'],
      ['SUCCESS', '전부 정상 적재. 모든 항목이 COMPLETED가 됩니다.'],
      ['PARTIAL',
        '일부만 실었음. 실은 항목은 COMPLETED, 뺀 항목은 FAILED가 됩니다. 명령 자체는 정상 ' +
        '종료로 봅니다.'],
      ['OVERWEIGHT / OVERVOLUME',
        '실제로 재 보니 상한을 넘었음. 명령이 실패로 끝나고 관련 항목이 전부 FAILED가 됩니다.'],
      ['ABORTED', '중단됨. 위와 같이 전부 FAILED가 됩니다.'],
    ]),
    body(
      '값이 앞뒤가 안 맞으면(예: "정상 완료인데 중량 초과") 시스템이 보고 자체를 거부합니다 — ' +
      '잘못된 기록이 남지 않도록 하기 위해서입니다.',
      { italics: true },
    ),
  ]),
  ...section('매니페스트 — 무엇이 어디에 실렸는가', [
    body(
      '매니페스트는 "이 팔레트에 무엇이 몇 번째 자리에 실렸는가"를 보여 줍니다. 선언 중량과 ' +
      '실측 중량이 나란히 표시되므로 둘의 차이도 바로 보입니다.',
    ),
    ...shot('11-pallet-manifest.png', '적재 위치·결과·매장·SKU가 항목별로 보이는 매니페스트'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 8 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('8. 스트레치 필름 포장')] }),
  ...section('하는 일', [
    body(
      '팔레트가 완성되면 같은 카드의 아래쪽 줄에서 Wrap Cell, Pallet Code, Wrap Program' +
      '(STANDARD 또는 HEAVY)을 고르고 Dispatch WRAP을 누릅니다.',
    ),
    ...shot('12-wrap-dispatched.png', 'HEAVY 프로그램으로 포장 명령을 보낸 모습'),
    body(
      '포장 명령은 서열 배정 상태를 전혀 바꾸지 않습니다 — 이미 끝난 팔레트를 감는 후속 공정일 ' +
      '뿐이기 때문입니다. 포장 결과는 WCS Monitor 화면의 이벤트 목록에서 확인합니다.',
    ),
    bullet('Wrap Program을 비워 두거나 STANDARD/HEAVY가 아닌 값을 넣으면 거부됩니다.'),
    bullet('로봇 셀이 아닌 설비에는 포장 명령을 보낼 수 없습니다.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 9 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('9. 역할별로 보이는 것이 다릅니다')] }),
  ...section('설비운영자 (WCS_OPERATOR)', [
    body(
      '서열 배정과 명령 전송은 할 수 있지만 출고 단위 등록 카드는 보이지 않습니다 — 무엇을 ' +
      '내보낼지는 상위 판단이기 때문입니다.',
    ),
    ...shot('13-operator-cannot-create-orders.png', '설비운영자 화면 — 출고 단위 등록 카드가 없습니다'),
    ...shot('14-heavy-pallet-dispatched.png', '설비운영자가 두 번째 셀로 무거운 팔레트를 보낸 모습'),
  ]),
  ...section('관리자 (WMS_ADMIN)', [
    body(
      '관리자는 출고 단위 등록과 서열 배정은 할 수 있지만 **설비 명령은 보낼 수 없습니다**. ' +
      '이것은 이 화면만의 규칙이 아니라 설비 제어 계약 전체의 규칙이며, 화면 위쪽에 노란 띠로 ' +
      '안내됩니다.',
    ),
    ...shot('16-admin-plans-only.png', '관리자 화면 — 명령 버튼이 없고 안내 문구가 보입니다'),
    body('계획 작업 자체는 정상적으로 됩니다 — 아래는 관리자가 취소된 건을 다시 배정한 모습입니다.'),
    ...shot('17-admin-resequenced.png', '관리자가 4번 자리로 재배정한 결과'),
  ]),
  ...section('그 외 역할', [
    body('세 권한 중 아무것도 없는 역할은 현황만 볼 수 있고 입력 카드가 전혀 보이지 않습니다.'),
    ...shot('18-read-only-role.png', '조회 전용 역할이 보는 화면'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 10 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('10. 취소하고 다시 배정하기')] }),
  ...section('하는 일', [
    body(
      '서열 배정 표 오른쪽 Cancel 버튼을 누르면 그 배정이 취소됩니다. 대기 중(QUEUED)이든 이미 ' +
      '내려간 뒤(DISPATCHED)든 취소할 수 있고, 이미 끝난 건(COMPLETED/FAILED)은 취소할 수 ' +
      '없습니다.',
    ),
    ...shot('15-dispatched-sequence-cancelled.png', '이미 내려간 배정을 취소해 설비 명령까지 함께 취소된 모습'),
  ]),
  ...section('꼭 알아야 할 두 가지', [
    infoTable([
      ['상황', '어떻게 되는가'],
      ['이미 내려간 배정을 취소하면',
        '그 배정이 타고 있던 PALLETIZE 명령이 함께 취소됩니다. 그리고 **같은 명령에 실려 있던 ' +
        '다른 배정들도 함께 취소**됩니다 — 명령이 사라졌으니 그 배정들만 "진행 중"으로 남겨 두면 ' +
        '거짓말이 되기 때문입니다. 알림 띠에 몇 건이 함께 취소됐는지 표시됩니다.'],
      ['취소하면 출고 단위는',
        'OPEN으로 되돌아갑니다. 그래서 방금 비운 서열 번호와 다른 팔레트로 곧바로 다시 배정할 수 ' +
        '있습니다.'],
    ]),
    body(
      '주의: 이 취소는 재고에 아무 영향이 없습니다. 애초에 이 화면이 재고를 잡아 두지 않기 ' +
      '때문입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- FAQ ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 겪는 상황')] }),
  infoTable([
    ['증상', '원인과 대처'],
    ['"is already taken in wave"',
      '그 웨이브에서 이미 쓴 서열 번호입니다. 다른 번호를 쓰거나, 그 번호를 쓰던 배정을 먼저 ' +
      '취소하세요.'],
    ['"is not OPEN (status=SEQUENCED)"',
      '이미 서열이 매겨진 출고 단위입니다. 다시 배정하려면 기존 배정을 먼저 취소하세요.'],
    ['"dispatch wave ... is not OPEN"',
      '릴리즈된 웨이브입니다. 새 웨이브를 열고 거기에 배정하세요.'],
    ['"exceeds max_weight_kg"',
      '선언 중량 합계가 상한을 넘었습니다. 상한을 조정하거나 팔레트를 나누세요(4장).'],
    ['"no QUEUED dispatch sequence for wave ... and pallet ..."',
      '그 팔레트에 대기 중인 항목이 없습니다. 팔레트 코드 오타이거나 이미 전부 내려간 상태입니다.'],
    ['"one cell builds one pallet at a time"',
      '그 셀이 다른 팔레트를 쌓는 중입니다. 다른 셀을 고르거나 끝날 때까지 기다리세요.'],
    ['"is only valid for ROBOT_CELL equipment"',
      '로봇 셀이 아닌 설비를 골랐습니다. 팔레타이징과 포장은 로봇 셀 전용입니다.'],
    ['"expected version ... but found ..."',
      '다른 사람이 먼저 바꿨습니다. Refresh를 눌러 최신 상태를 받은 뒤 다시 시도하세요.'],
    ['명령 버튼이 안 보임',
      '현재 역할에 명령 권한이 없습니다(9장). 노란 안내 띠를 확인하세요.'],
    ['매니페스트가 "결과 미보고"',
      '오류가 아닙니다. 로봇 셀이 아직 답을 주지 않았을 뿐입니다(6장).'],
  ]),

  new Paragraph({ spacing: { before: 400 }, children: [new TextRun({
    text:
      '이 매뉴얼의 모든 화면은 실제 자동화 테스트(wcs-sequential-dispatch-flow.spec.ts)가 ' +
      '로컬 Supabase를 상대로 돌면서 캡처한 것입니다. 계약의 상세 규칙과 검증 결과는 ' +
      'openspec/specs/wms_wcs-sequential-dispatch/ 아래 spec.md와 e2e/README.md를 참고하세요.',
    size: 20, color: '64748B', italics: true,
  })] }),
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
        children: [new TextRun({ text: '서열 출고/지능형 적재 · 출고 단위/서열 배정/혼합 팔레타이징 운영 매뉴얼', size: 18, color: '94A3B8' })],
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
