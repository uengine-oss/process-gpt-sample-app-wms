// Builds the WCS 설비 제어 운영자 매뉴얼 (.docx) from the screenshots captured
// by frontend/playwright/e2e/wcs-equipment-flow.spec.ts.
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
const OUT = path.resolve(HERE, 'wcs-equipment-control-operator-manual.docx')

// US Letter, 1" margins -> 9360 DXA of content width.
const CONTENT_DXA = 9360
// Screenshots are 1280x~720-760 CSS px; scale to fit the text column (6.5in).
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
    children: [new TextRun({ text: 'WCS 자동화 설비 제어', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '운영자 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 설비운영자(WCS_OPERATOR)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '창고관리자, 설비운영자'],
    ['다루는 화면', 'WCS Equipment (/wcs/equipment), WCS Monitor (/wcs/monitor)'],
    ['필요 권한', '설비 등록: WMS_ADMIN 또는 WAREHOUSE_MANAGER / 장애 해소: WCS_OPERATOR, WAREHOUSE_MANAGER, WMS_ADMIN'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (wcs-equipment-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 매뉴얼은 창고의 자동화 설비(스태커 크레인, 컨베이어, 분류기, AGV/AMR, 로봇 적재 셀)를 ' +
    'WMS 화면에서 등록하고, 제어 명령을 내리고, 설비가 보고한 상태를 확인하고, 장애가 생겼을 때 ' +
    '복구하는 방법을 순서대로 설명합니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('누가 무엇을 하는가')] }),
  body(
    'WCS 설비 제어에는 사람과 설비, 두 축이 있습니다. 화면에서 일하는 쪽은 사람이고, ' +
    '설비 쪽은 화면에 로그인하지 않습니다.',
  ),
  bullet('창고관리자(WAREHOUSE_MANAGER): 설비를 레지스트리에 등록하고, 설비에 제어 명령을 내립니다.'),
  bullet('설비운영자(WCS_OPERATOR): 설비 현황을 모니터링하고, 수동 명령을 내리고, 장애를 해소합니다.'),
  bullet(
    'WCS 게이트웨이(WCS_GATEWAY): 사람이 아니라 설비 쪽 시스템입니다. 명령을 받아 수행하고 그 결과와 ' +
    '상태 변화, 장애 발생을 WMS에 자동으로 되돌려 보고합니다. 이 매뉴얼에서 "게이트웨이가 보고합니다"라고 ' +
    '적힌 단계는 사람이 누르는 버튼이 아니라 설비가 스스로 하는 일입니다.',
  ),
  body(
    '장애 해소만은 게이트웨이가 할 수 없습니다. 설비가 스스로 "고쳐졌다"고 선언하게 두지 않고, ' +
    '반드시 사람이 현장을 확인한 뒤 사유를 적어 닫도록 되어 있습니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('설비 상태 읽는 법')] }),
  infoTable([
    ['상태', '의미'],
    ['OFFLINE', '등록은 되었으나 아직 기동하지 않음. 새 설비의 최초 상태입니다.'],
    ['IDLE', '기동 완료, 대기 중. 이 상태에서만 새 명령을 보낼 수 있습니다.'],
    ['RUNNING', '진행 중인 명령이 있음.'],
    ['FAULT', '장애 발생. 해소하기 전까지 새 명령을 받지 않습니다.'],
    ['MAINTENANCE', '계획 정비 중. 새 명령을 받지 않습니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- steps ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 설비 등록')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴에서 WCS Equipment를 선택하면 이 창고에 등록된 설비 목록이 나옵니다.'),
    body('상단 "설비 등록" 카드에 세 가지를 입력합니다.'),
    bullet('Equipment Code — 창고 안에서 유일해야 하는 설비 번호입니다 (예: AGV-07). 이미 쓰인 코드를 다시 넣으면 오류가 납니다.'),
    bullet('Type — 설비 종류를 고릅니다 (SRM / CONVEYOR / SORTER / AGV / AMR / ROBOT_CELL).'),
    bullet('Zone — 설비가 놓인 구역 코드입니다 (예: ZONE-B).'),
    body('입력을 마치고 Register Equipment 버튼을 누릅니다.'),
    ...shot('01-register-form.png', '설비 등록 정보를 입력한 상태'),
  ]),
  ...section('결과 확인', [
    body(
      '아래 목록에 새 설비가 나타나고 상태는 OFFLINE, Version은 1입니다. 아직 설비가 기동하지 않았기 ' +
      '때문에 정상입니다. 이 시점에는 Dispatch 열에 "대기(IDLE) 상태에서만 가능"이라고 표시됩니다.',
    ),
    ...shot('02-registered-offline.png', '등록 직후 — 상태 OFFLINE, Version 1'),
    body(
      '설비 등록 카드는 창고관리자와 시스템관리자에게만 보입니다. 권한이 없는 역할로 로그인하면 ' +
      '카드 자체가 표시되지 않습니다.',
      { italics: true },
    ),
    ...shot('11-operator-no-register.png', '설비운영자로 로그인하면 등록 카드가 보이지 않습니다'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 설비 기동 확인 (게이트웨이 자동 보고)')] }),
  ...section('하는 일', [
    body(
      '설비에 전원이 들어오고 통신이 연결되면, WCS 게이트웨이가 WMS에 "이제 대기 상태다"라고 스스로 ' +
      '보고합니다. 운영자가 눌러야 할 버튼은 없습니다. 화면을 새로고침하면 상태가 OFFLINE에서 IDLE로 ' +
      '바뀐 것을 볼 수 있습니다.',
    ),
    body(
      'Version이 1에서 2로 올라간 점도 함께 확인하세요. 설비 상태가 바뀔 때마다 Version이 1씩 증가하며, ' +
      '이 숫자는 여러 사람이 동시에 같은 설비를 조작하다가 서로의 작업을 덮어쓰는 사고를 막는 안전장치입니다.',
    ),
    ...shot('03-online-idle.png', '기동 완료 — 상태 IDLE, Version 2, 이제 명령 입력란이 나타남'),
    body(
      '설비가 오랫동안 OFFLINE에 머물러 있다면 설비 자체나 게이트웨이 통신을 점검해야 합니다. ' +
      'WMS 화면에서 강제로 IDLE로 바꿀 수는 없습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 제어 명령 디스패치')] }),
  ...section('하는 일', [
    body(
      '상태가 IDLE인 설비의 Dispatch 열에 목적지 구역을 입력하고 Dispatch MOVE를 누르면 이동 명령이 ' +
      '설비로 전달됩니다. 예시에서는 ZONE-C를 입력했습니다.',
    ),
    body(
      '명령을 보내면 두 가지가 동시에 바뀝니다. 설비 상태는 RUNNING이 되고, In-flight 열에 ' +
      '"MOVE / PENDING"이 표시됩니다. PENDING은 "설비에 전달되었으나 아직 설비가 접수 확인을 ' +
      '보내오지 않았다"는 뜻입니다.',
    ),
    ...shot('04-command-dispatched.png', '명령 디스패치 직후 — 설비 RUNNING, 명령 MOVE / PENDING'),
  ]),
  ...section('모니터 화면에서 보기', [
    body(
      '왼쪽 메뉴 WCS Monitor로 옮기면 같은 상황을 운영 관점으로 볼 수 있습니다. 설비 카드에 ' +
      '"진행 중 명령: MOVE (PENDING)"이 표시되고, 아래 이벤트 표에 상태 변화 이력이 시간순으로 쌓입니다.',
    ),
    ...shot('05-monitor-in-flight.png', 'WCS Monitor — 진행 중 명령과 이벤트 이력'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 명령 완료 보고 확인 (게이트웨이 자동 보고)')] }),
  ...section('하는 일', [
    body(
      '설비는 명령을 처리하면서 진행 상황을 단계별로 되돌려 보고합니다. 운영자는 모니터 화면을 ' +
      '새로고침해 이 흐름을 확인하면 됩니다.',
    ),
    bullet('COMMAND_ACKNOWLEDGED — 설비가 명령을 접수했습니다.'),
    bullet('COMMAND_PROGRESS — 설비가 작업을 수행 중입니다.'),
    bullet('COMMAND_COMPLETED — 작업이 끝났습니다. 상세 항목에 설비가 보낸 값(예: 이동 거리)이 함께 남습니다.'),
    body(
      '명령이 끝나고 이 설비에 다른 진행 중 명령이 없으면, 설비 상태는 자동으로 RUNNING에서 IDLE로 ' +
      '되돌아갑니다. 즉 다음 명령을 받을 준비가 되었다는 뜻입니다.',
    ),
    ...shot('06-monitor-completed.png', '완료 보고 반영 — 설비 IDLE, 이벤트에 COMMAND_COMPLETED 기록'),
    body(
      '완료된 명령은 이벤트 이력에 영구히 남습니다. 나중에 "그때 그 AGV가 몇 시에 무엇을 했는가"를 ' +
      '되짚어야 할 때 이 표를 보면 됩니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 설비 장애 발생')] }),
  ...section('무슨 일이 일어나는가', [
    body(
      '설비가 이상을 감지하면 게이트웨이가 즉시 장애를 보고합니다. 예시는 모터 과열' +
      '(MOTOR_OVERHEAT, 심각도 CRITICAL)입니다. 이때 WMS는 세 가지를 한 번에 처리합니다.',
    ),
    bullet('설비 상태를 FAULT로 바꿉니다.'),
    bullet('그 설비에서 진행 중이던 명령을 모두 실패(COMMAND_FAILED) 처리하고 이 장애와 연결합니다.'),
    bullet('모니터 화면 상단에 빨간 장애 배너를 띄웁니다.'),
    body(
      '진행 중이던 명령을 자동으로 실패시키는 이유는, 장애 난 설비가 "아직 뭔가 하고 있는 중"으로 ' +
      '남아 있으면 다음 작업 배분이 잘못되기 때문입니다. 실패한 명령을 다시 보낼지는 복구 후 ' +
      '사람이 판단합니다.',
    ),
    ...shot('07-fault-raised.png', '장애 발생 — 설비 FAULT, 진행 중이던 명령은 COMMAND_FAILED로 종결'),
  ]),
  ...section('장애 중에는 명령을 보낼 수 없습니다', [
    body(
      '설비 목록 화면으로 돌아가면 Dispatch 열에 "장애 해소 후 가능"이라고 표시되고 명령 입력란이 ' +
      '사라집니다. 장애 상태에서 억지로 명령을 보내려 해도 시스템이 거부합니다.',
    ),
    ...shot('08-dispatch-blocked.png', '장애 상태에서는 명령 디스패치가 차단됨'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 장애 해소 및 재가동')] }),
  ...section('하는 일', [
    body(
      '현장에서 설비를 점검하고 조치를 마친 뒤, 설비운영자(WCS_OPERATOR)가 WCS Monitor 화면에서 ' +
      '장애를 닫습니다. 장애 배너의 입력란에 무엇을 했는지 적고 Resolve Fault를 누릅니다.',
    ),
    body(
      '해소 사유는 반드시 입력해야 합니다. 비워 두면 시스템이 거부합니다. 이 기록은 나중에 같은 장애가 ' +
      '반복될 때 원인을 추적하는 근거가 되므로, "확인함" 같은 말 대신 실제로 한 조치를 구체적으로 ' +
      '적어 주세요.',
    ),
    ...shot('09-operator-resolving.png', '설비운영자가 해소 사유를 입력한 상태'),
  ]),
  ...section('결과 확인', [
    body(
      'Resolve Fault를 누르면 장애 배너가 사라지고 설비 상태가 IDLE로 돌아옵니다. 이벤트 이력에는 ' +
      'FAULT_CLEARED가 추가되고, 누가 언제 어떤 사유로 닫았는지가 함께 저장됩니다.',
    ),
    body(
      '장애로 실패 처리되었던 명령은 되살아나지 않습니다. 필요하면 설비가 IDLE로 돌아온 지금 ' +
      '3단계 절차대로 명령을 다시 디스패치하세요.',
    ),
    ...shot('10-fault-resolved.png', '장애 해소 완료 — 설비 IDLE, 이벤트에 FAULT_CLEARED 기록'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- troubleshooting ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 빨간 띠로 표시되는 오류 메시지의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 사람이나 설비가 먼저 상태를 바꿨습니다. 화면을 새로고침한 뒤 다시 시도하세요. 덮어쓰기 사고를 막기 위한 정상 동작입니다.'],
    ['FORBIDDEN: role cannot …',
      '현재 로그인한 역할에는 이 작업 권한이 없습니다. 화면 오른쪽 위 역할 배지를 확인하고, 권한이 있는 담당자에게 요청하세요.'],
    ['INVALID: equipment_code … already registered',
      '같은 창고에 이미 있는 설비 번호입니다. 다른 번호를 쓰거나 기존 설비를 사용하세요.'],
    ['INVALID: equipment … is in FAULT',
      '장애 중인 설비에 명령을 보내려 했습니다. 먼저 6단계대로 장애를 해소하세요.'],
    ['INVALID: resolution_note is required',
      '해소 사유를 입력하지 않았습니다. 실제로 취한 조치를 적어 주세요.'],
    ['해소 권한이 없습니다 (WCS_OPERATOR 필요)',
      '장애 해소는 설비운영자, 창고관리자, 시스템관리자만 가능합니다.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/wcs-equipment-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: 'WCS 자동화 설비 제어 · 운영자 매뉴얼', size: 18, color: '94A3B8' })],
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
