// Builds the 야드/도크 스케줄링 운영자 매뉴얼 (.docx) from the screenshots
// captured by frontend/playwright/e2e/dock-schedule-flow.spec.ts.
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
const OUT = path.resolve(HERE, 'yard-dock-scheduling-operator-manual.docx')

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

const children = [
  // ---------------- title page ----------------
  new Paragraph({ spacing: { before: 2400, after: 120 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '야드 및 도크 관리', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '운영자 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '입고담당자(INBOUND_OPERATOR) · 창고관리자(WAREHOUSE_MANAGER)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '입고담당자, 창고관리자'],
    ['다루는 화면', 'Dock Schedule (/inbound/dock-schedule)'],
    ['필요 권한', '도크 등록·정비: WMS_ADMIN 또는 WAREHOUSE_MANAGER / 예약 생성·취소: INBOUND_OPERATOR, WMS_ADMIN / 차량 체크인·도킹·출차: INBOUND_OPERATOR, WMS_ADMIN'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (dock-schedule-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 매뉴얼은 창고의 하역장(도크)을 등록하고, 들어오거나 나가는 차량에 도크와 시간을 배정하고, ' +
    '그 차량이 야드에 들어와 도크에 붙었다가 떠나는 과정을 화면에서 기록하는 방법을 순서대로 설명합니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('왜 도크를 관리하나')] }),
  body(
    '도크는 개수가 정해진 물리적 자원입니다. 같은 시간에 같은 문으로 트럭 두 대가 들어올 수는 없습니다. ' +
    '전화와 엑셀로 일정을 잡으면 이 사실이 지켜지지 않아 트럭이 마당에서 대기하고, 하역 인력이 놀고, ' +
    '공급사에는 지체료가 발생합니다.',
  ),
  body(
    '이 화면은 그 문제를 시스템이 대신 막아 줍니다. 같은 도크에 시간이 겹치는 예약을 만들려고 하면 ' +
    '데이터베이스가 그 예약 자체를 거부합니다 — 화면이 확인하고 나서 저장하는 것이 아니라, ' +
    '저장 시점에 원자적으로 거부되므로 두 사람이 동시에 같은 슬롯을 잡아도 정확히 한 명만 성공합니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('누가 무엇을 하는가')] }),
  bullet('창고관리자(WAREHOUSE_MANAGER) / 시스템관리자(WMS_ADMIN): 도크를 등록하고, 정비를 위해 도크를 닫거나 다시 엽니다.'),
  bullet('입고담당자(INBOUND_OPERATOR): 도크 예약을 만들고 취소하며, 차량의 야드 체크인 · 도킹 · 출차를 기록합니다.'),
  bullet(
    '자동화 에이전트(PROCESS_AGENT): 예약을 만들고 취소하고 스케줄을 조회할 수 있습니다. ' +
    '그러나 체크인 · 도킹 · 출차는 할 수 없습니다 — 이 세 가지는 "트럭이 실제로 움직였다"는 ' +
    '현장 관찰을 기록하는 행위이므로, 반드시 사람이 눈으로 확인하고 눌러야 합니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('도크 상태 읽는 법')] }),
  infoTable([
    ['상태', '의미'],
    ['AVAILABLE', '비어 있음. 예약을 잡을 수 있고, 차량이 접안할 수 있습니다. 새 도크의 최초 상태입니다.'],
    ['OCCUPIED', '차량이 접안해 하역 중. 사람이 직접 지정하는 값이 아니라, 도킹을 기록하면 자동으로 그렇게 됩니다.'],
    ['CLOSED', '정비 등으로 닫힘. 새 예약을 받지 않습니다. 관리자가 수동으로 닫고 엽니다.'],
  ]),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('예약 상태 읽는 법')] }),
  infoTable([
    ['상태', '의미'],
    ['SCHEDULED', '슬롯이 잡혔고 차량은 아직 도착 전입니다.'],
    ['CHECKED_IN', '차량이 야드(마당)에 들어왔습니다. 아직 도크에 붙지는 않았습니다.'],
    ['AT_DOCK', '차량이 도크에 접안해 하역 중입니다. 이때 도크가 OCCUPIED가 됩니다.'],
    ['DEPARTED', '하역을 마치고 떠났습니다. 도크는 다시 AVAILABLE이 됩니다.'],
    ['CANCELLED', '취소되었습니다. 그 시간창은 즉시 다시 예약할 수 있습니다.'],
  ]),
  body(
    '진행 중인 예약(SCHEDULED · CHECKED_IN · AT_DOCK)만 시간 겹침 판정에 들어갑니다. ' +
    '취소되었거나 이미 떠난 예약은 판정에서 빠지므로, 그 슬롯은 바로 다시 쓸 수 있습니다.',
    { italics: true },
  ),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 1 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 도크 등록')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴 WMS 그룹에서 Dock Schedule을 선택하면 이 창고의 도크 목록과 오늘 예약 현황이 나옵니다.'),
    body('상단 "도크 등록" 카드에 두 가지를 입력합니다.'),
    bullet('Dock Code — 창고 안에서 유일해야 하는 도크 번호입니다 (예: DOCK-04). 이미 쓰인 코드를 다시 넣으면 오류가 납니다.'),
    bullet('Dock Name — 사람이 알아보는 이름입니다 (예: 입고 하역장 4).'),
    body('입력을 마치고 Register Dock 버튼을 누릅니다.'),
    ...shot('01-register-dock-form.png', '도크 등록 정보를 입력한 상태'),
  ]),
  ...section('결과 확인', [
    body(
      '아래 "도크 현황" 표에 새 도크가 나타나고 상태는 AVAILABLE, Version은 1입니다. ' +
      '등록하자마자 예약을 받을 수 있는 상태입니다.',
    ),
    body(
      'Version은 여러 사람이 동시에 같은 도크를 조작하다가 서로의 작업을 덮어쓰는 사고를 막는 ' +
      '안전장치입니다. 상태가 바뀔 때마다 1씩 올라갑니다.',
    ),
    ...shot('02-docks-registered.png', '도크 두 개 등록 완료 — 둘 다 AVAILABLE'),
    body(
      '도크 등록 카드는 창고관리자와 시스템관리자에게만 보입니다. 입고담당자로 로그인하면 ' +
      '카드 자체가 표시되지 않습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 2 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 도크 예약 만들기')] }),
  ...section('하는 일', [
    body('입고담당자로 로그인하면 "도크 예약" 카드가 보입니다. 다음 항목을 채웁니다.'),
    bullet('Dock — 배정할 도크를 고릅니다. 괄호 안에 현재 상태가 함께 표시됩니다.'),
    bullet('Type — INBOUND(입고)인지 OUTBOUND(출고)인지 고릅니다.'),
    bullet('Purchase Order — INBOUND일 때만 나타납니다. 어떤 발주 건의 화물인지 반드시 지정해야 합니다.'),
    bullet('Start / End — 하역 예정 시간창입니다. 종료 시각이 시작 시각보다 뒤여야 합니다.'),
    bullet('Carrier / Plate No — 운송사와 차량 번호입니다. 지금 모르면 비워 두고 나중에 체크인할 때 채워도 됩니다.'),
    body('Schedule Appointment를 누르면 아래 타임라인 표에 SCHEDULED 상태로 나타납니다.'),
    ...shot('03-appointment-scheduled.png', '09:00–10:00 예약 생성 완료 — 상태 SCHEDULED'),
  ]),
  ...section('시간창은 어떻게 세나', [
    body(
      '시간창은 "시작 시각은 포함, 종료 시각은 제외"로 계산합니다. 그래서 09:00–10:00 예약과 ' +
      '10:00–11:00 예약은 겹치지 않습니다 — 같은 도크에 연달아 붙여 잡을 수 있습니다. ' +
      '반면 09:00–10:00과 09:30–10:30은 30분이 겹치므로 함께 존재할 수 없습니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 3 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 이중 예약은 시스템이 막습니다')] }),
  ...section('무슨 일이 일어나나', [
    body(
      '이미 09:00–10:00 예약이 있는 도크에 09:30–10:30으로 다시 예약을 시도하면, 화면 위쪽에 ' +
      '빨간 띠로 CONFLICT 오류가 뜨고 예약은 만들어지지 않습니다. 타임라인 표에도 아무것도 ' +
      '추가되지 않습니다.',
    ),
    ...shot('04-double-booking-rejected.png', '겹치는 시간창 — CONFLICT 오류, 예약 생성 안 됨'),
    body(
      '이 거부는 화면이 미리 조회해 보고 판단한 결과가 아니라 데이터베이스가 저장 시점에 내리는 ' +
      '판정입니다. 그래서 두 담당자가 같은 슬롯을 동시에 잡으려 해도 정확히 한 명만 성공하고, ' +
      '나머지 한 명은 이 오류를 받습니다. "조회했을 땐 비어 있었는데 둘 다 저장됐다"는 상황이 ' +
      '구조적으로 발생하지 않습니다.',
      { italics: true },
    ),
  ]),
  ...section('막히지 않는 경우', [
    body(
      '겹침 판정은 도크별로, 시간창별로 따로 계산됩니다. 같은 시간대라도 다른 도크라면 문제없이 ' +
      '예약됩니다. 아래 예시는 두 번째 도크의 09:30–10:30을 정상적으로 잡은 화면입니다.',
    ),
    ...shot('05-second-dock-booked.png', '다른 도크의 같은 시간대는 정상 예약'),
    body('오류가 났을 때 할 수 있는 일은 세 가지입니다.'),
    bullet('시간을 옮긴다 — 예약이 끝나는 시각 이후로 잡으면 됩니다.'),
    bullet('다른 도크로 옮긴다 — 도크 현황 표에서 비어 있는 도크를 확인하세요.'),
    bullet('기존 예약을 취소한다 — 그 슬롯이 정말 필요하다면 6단계를 참고하세요.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 4 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 차량 야드 체크인')] }),
  ...section('하는 일', [
    body(
      '예약된 차량이 정문을 통과해 마당(야드)에 들어오면, 타임라인 표의 해당 예약 행에서 ' +
      'Check In 버튼을 누릅니다. 예약 상태가 SCHEDULED에서 CHECKED_IN으로 바뀝니다.',
    ),
    body(
      '이때 도크 상태는 바뀌지 않습니다. AVAILABLE 그대로입니다. 차량이 마당에는 있지만 아직 ' +
      '문에 붙지 않았기 때문입니다 — 이 구분이 있어야 "몇 대가 대기 중인지"와 "몇 개 문이 ' +
      '실제로 막혀 있는지"를 따로 셀 수 있습니다.',
    ),
    ...shot('06-vehicle-checked-in.png', '체크인 완료 — 예약 CHECKED_IN, 도크는 여전히 AVAILABLE'),
    body(
      '체크인하려는 순간 그 도크에 다른 차량이 붙어 있다면 체크인 자체는 성공하지만 ' +
      '"도크가 현재 점유 중"이라는 안내가 함께 표시됩니다. 앞 차량이 떠날 때까지 마당에서 ' +
      '기다리면 됩니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 5 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 도킹과 출차')] }),
  ...section('도킹 — 문을 점유합니다', [
    body(
      '차량이 후진해 도크에 접안하면 Dock Vehicle을 누릅니다. 두 가지가 동시에 바뀝니다: ' +
      '예약은 AT_DOCK이 되고, 도크는 OCCUPIED가 됩니다.',
    ),
    ...shot('07-vehicle-at-dock.png', '도킹 완료 — 예약 AT_DOCK, 도크 OCCUPIED'),
    body(
      '도크가 이미 다른 차량으로 점유되어 있거나 정비로 닫혀 있으면 도킹은 거부되고, ' +
      '예약과 도크 어느 쪽도 바뀌지 않습니다.',
    ),
  ]),
  ...section('하역 중에 할 일 — 입하 접수', [
    body(
      '차량이 도크에 붙어 있는 동안 실제 화물 접수는 Receiving 화면에서 따로 진행합니다. ' +
      '도크 예약과 입하 접수는 서로 다른 문서입니다.',
    ),
    body(
      '중요한 점: 도크 예약이 없어도 입하 접수는 정상적으로 됩니다. 반대로 도킹을 기록했다고 ' +
      '입하 접수가 자동으로 되지도 않습니다. 트럭 한 대에 여러 발주 건의 화물이 섞여 오는 일이 ' +
      '흔하기 때문에, 두 기록을 1:1로 묶지 않았습니다. 권장 순서는 체크인 → 도킹 → ' +
      'Receiving 화면에서 입하 접수 → 출차이지만, 이는 운영 절차이지 시스템이 강제하는 순서가 ' +
      '아닙니다.',
      { italics: true },
    ),
  ]),
  ...section('출차 — 문을 비웁니다', [
    body(
      '하역이 끝나 차량이 떠나면 Depart를 누릅니다. 예약은 DEPARTED가 되고 도크는 AVAILABLE로 ' +
      '돌아가, 다음 차량을 받을 수 있게 됩니다.',
    ),
    ...shot('08-vehicle-departed.png', '출차 완료 — 예약 DEPARTED, 도크 AVAILABLE 복귀'),
    body(
      '차량이 하역하는 동안 관리자가 그 도크를 정비 대상으로 닫아 둔 경우에는, 출차해도 도크가 ' +
      'AVAILABLE로 돌아가지 않고 CLOSED로 남습니다. 출차가 정비 결정을 덮어쓰지 않도록 한 ' +
      '것이며, 화면에 그 사실이 안내됩니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 6 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 예약 취소와 슬롯 재사용')] }),
  ...section('하는 일', [
    body(
      '공급사 사정으로 일정이 바뀌면 예약을 취소합니다. 아직 도크에 붙지 않은 예약 ' +
      '(SCHEDULED 또는 CHECKED_IN)에만 Cancel 버튼이 나타납니다. 이미 도킹한 예약은 ' +
      '취소할 수 없습니다 — 차량이 물리적으로 문에 붙어 있는 사실을 "없던 일"로 되돌리지 ' +
      '않기 위해서입니다. 하역을 마쳤다면 취소가 아니라 출차로 닫으세요.',
    ),
    body('아래는 13:00–14:00 슬롯이 이미 잡혀 있어 같은 시간창 예약이 거부된 화면입니다.'),
    ...shot('09-slot-taken.png', '이미 잡힌 슬롯 — CONFLICT'),
  ]),
  ...section('취소하면 슬롯이 바로 풀립니다', [
    body(
      'Cancel을 누르면 예약 상태가 CANCELLED로 바뀌고, 화면에 "해당 시간창은 다시 예약할 수 ' +
      '있습니다"라는 안내가 표시됩니다.',
    ),
    ...shot('10-appointment-cancelled.png', '취소 완료 — 상태 CANCELLED'),
    body(
      '취소된 예약은 겹침 판정에서 즉시 빠집니다. 그래서 방금 거부당했던 그 시간창을 바로 다시 ' +
      '잡을 수 있습니다. 별도의 정리 작업이나 대기 시간이 필요 없습니다.',
    ),
    ...shot('11-slot-rebooked.png', '같은 13:00–14:00 슬롯을 다른 운송사로 재예약'),
    body(
      '취소된 예약 행은 목록에서 사라지지 않고 CANCELLED 상태로 남습니다. "누가 언제 무엇을 ' +
      '취소했는가"가 기록으로 남아야 하기 때문입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 7 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('7. 도크 정비 (닫기 / 다시 열기)')] }),
  ...section('하는 일', [
    body(
      '창고관리자로 로그인하면 도크 현황 표 오른쪽에 정비 열이 나타납니다. AVAILABLE 도크에는 ' +
      'Close 버튼이, CLOSED 도크에는 Reopen 버튼이 표시됩니다.',
    ),
    ...shot('12-manager-role-view.png', '창고관리자 화면 — 도크 등록 카드와 정비 버튼만 보임'),
    body('닫힌 도크에는 새 예약을 만들 수 없습니다. 정비가 끝나면 Reopen으로 다시 엽니다.'),
    ...shot('13-dock-closed.png', 'DOCK-E2E-02를 정비를 위해 닫은 상태'),
    body(
      '점유 중(OCCUPIED)인 도크는 닫을 수 없습니다. 버튼 대신 "점유 중 — 출차 후 가능"이라고 ' +
      '표시됩니다. 하역 중인 차량을 유령 상태로 만들지 않기 위한 제한입니다.',
      { italics: true },
    ),
  ]),
  ...section('역할에 따라 화면이 다릅니다', [
    body(
      '창고관리자에게는 예약 폼과 차량 버튼(Check In / Dock Vehicle / Depart)이 아예 보이지 ' +
      '않고, 입고담당자에게는 도크 등록 카드와 정비 버튼이 보이지 않습니다. 권한이 없는 작업은 ' +
      '버튼을 눌러 보고 거절당하는 대신 처음부터 화면에 나타나지 않습니다.',
    ),
    ...shot('14-operator-role-view.png', '입고담당자 화면 — 예약 폼과 차량 버튼만 보임'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- troubleshooting ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 빨간 띠로 표시되는 오류 메시지의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['CONFLICT: dock … already has an active appointment overlapping …',
      '같은 도크에 시간이 겹치는 예약이 이미 있습니다. 시간을 옮기거나, 다른 도크를 고르거나, 기존 예약을 취소하세요. 도크 현황 표의 "오늘 예약" 수와 타임라인을 먼저 확인하면 빠릅니다.'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 사람이 먼저 이 예약이나 도크를 바꿨습니다. Refresh를 누른 뒤 다시 시도하세요. 덮어쓰기 사고를 막기 위한 정상 동작입니다.'],
    ['FORBIDDEN: role cannot …',
      '현재 로그인한 역할에는 이 작업 권한이 없습니다. 화면 오른쪽 위 역할 배지를 확인하고, 권한이 있는 담당자에게 요청하세요.'],
    ['INVALID: dock code … already registered',
      '같은 창고에 이미 있는 도크 번호입니다. 다른 번호를 쓰거나 기존 도크를 사용하세요.'],
    ['INVALID: scheduled_end must be after scheduled_start',
      '종료 시각을 시작 시각보다 앞이나 같게 넣었습니다. 시간을 다시 확인하세요.'],
    ['INVALID: po_id is required for an INBOUND appointment',
      '입고 예약인데 발주 건을 고르지 않았습니다. 목록이 비어 있다면 확정된 발주가 아직 없는 것이므로 Purchase Orders 화면에서 먼저 발주를 확정하세요.'],
    ['INVALID: dock … is CLOSED and cannot be booked',
      '정비로 닫힌 도크입니다. 다른 도크를 고르거나, 관리자에게 도크를 다시 열어 달라고 요청하세요.'],
    ['INVALID: dock … is already OCCUPIED',
      '앞 차량이 아직 떠나지 않았습니다. 출차 처리가 끝난 뒤 도킹하세요.'],
    ['INVALID: dock … is OCCUPIED — depart the vehicle before changing its status',
      '하역 중인 도크를 닫으려 했습니다. 먼저 출차를 기록하세요.'],
    ['INVALID: appointment … cannot be cancelled',
      '이미 도킹했거나 떠났거나 취소된 예약입니다. 하역이 끝났다면 취소가 아니라 Depart로 닫으세요.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/dock-schedule-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: '야드 및 도크 관리 · 운영자 매뉴얼', size: 18, color: '94A3B8' })],
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
