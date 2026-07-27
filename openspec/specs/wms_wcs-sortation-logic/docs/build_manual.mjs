// Builds the 고속 분류 제어 운영자 매뉴얼 (.docx) from the screenshots captured
// by frontend/playwright/e2e/wcs-sortation-flow.spec.ts.
//
//   npm install -g docx      # or a local `npm install docx`
//   node build_manual.mjs
//
// Same generator shape as openspec/specs/wms_wcs-equipment-control/docs/build_manual.mjs
// and .../wms_wes-material-flow-control/docs/build_manual.mjs so the three
// manuals stay visually consistent. Every screenshot in this manual is a real
// frame from a passing Playwright run against a live local Supabase — nothing
// here is mocked up.

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
const OUT = path.resolve(HERE, 'wcs-sortation-logic-operator-manual.docx')

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
    children: [new TextRun({ text: '고속 분류 제어', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '분류 프로파일 · Divert · 속도 조정 운영 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 설비운영자(WCS_OPERATOR)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '창고관리자, 설비운영자'],
    ['다루는 화면', 'WCS Sortation (/wcs/sortation), 일부 WCS Monitor (/wcs/monitor)'],
    ['필요 권한', '프로파일 관리: WMS_ADMIN, WAREHOUSE_MANAGER, WCS_OPERATOR / 명령 전송: WAREHOUSE_MANAGER, WCS_OPERATOR (그 외 역할은 조회만)'],
    ['선행 준비', '분류기(SORTER) 또는 컨베이어(CONVEYOR)가 WCS Equipment 화면에 등록되어 있고 상태가 IDLE일 것 (별도 매뉴얼: WCS 자동화 설비 제어)'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (wcs-sortation-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 매뉴얼은 분류기(소터)와 컨베이어를 다루는 WCS Sortation 화면의 사용법을 설명합니다. ' +
    '화물을 어느 슈트로 보낼지 지시하고, 라인 속도를 조정하고, 분류가 제대로 됐는지 확인하는 ' +
    '절차를 순서대로 다룹니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('두 가지만 구분하면 됩니다')] }),
  bullet(
    '분류 프로파일 — 그 설비가 평소에 지켜야 할 기준값입니다. 화물 사이 최소 간격, 낼 수 있는 ' +
    '속도의 하한과 상한, 센서가 화물을 인식하는 시간 폭. 한 번 정해 두고 계속 씁니다.',
  ),
  bullet(
    '분류 명령 — 지금 이 화물 한 건을 어떻게 할지 보내는 지시입니다. DIVERT(어느 슈트로 보낼지)와 ' +
    'SET_SPEED(속도를 얼마로 바꿀지) 두 가지가 있습니다.',
  ),
  body(
    '프로파일은 "기준", 명령은 "지금 할 일"입니다. 그래서 프로파일이 없는 설비에는 명령을 보낼 수 ' +
    '없습니다 — 기준이 없으면 그 속도가 안전한지, 그 간격이 맞는지 확인할 방법이 없기 때문입니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('작업 순서')] }),
  infoTable([
    ['순서', '무엇을'],
    ['1. 설비 등록', 'WCS Equipment 화면에서 분류기를 등록합니다 (별도 매뉴얼).'],
    ['2. 프로파일 등록', '이 매뉴얼 3장. 설비당 한 번만 하면 됩니다.'],
    ['3. 분류 명령', '이 매뉴얼 4~5장. DIVERT / SET_SPEED를 필요할 때마다 보냅니다.'],
    ['4. 결과 확인', '이 매뉴얼 6~7장. 설비가 성공/오분류/잼 중 하나로 되돌려 보고합니다.'],
  ]),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('분류 결과 세 가지')] }),
  infoTable([
    ['결과', '뜻과 뒤따르는 일'],
    ['성공 (SUCCESS)', '지시한 슈트로 정상 배출됐습니다. 명령은 완료로 끝납니다.'],
    ['오분류 (MISROUTE)', '다른 슈트로 나갔습니다. 그 명령 한 건만 실패로 끝나고 설비는 계속 돌아갑니다. 해당 화물만 수동으로 되돌리면 됩니다.'],
    ['잼 (JAM)', '물리적으로 막혔습니다. 설비가 자동으로 장애 상태(FAULT)가 되고 그 설비에 걸려 있던 다른 명령도 함께 실패 처리됩니다. 사람이 현장을 확인하고 해소해야 다시 움직입니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- steps ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 화면 열기')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴에서 WCS Sortation을 선택합니다. 이 창고에 등록된 분류기와 컨베이어만 나옵니다 — AGV나 로봇 셀은 여기 대상이 아닙니다.'),
    body(
      '설비마다 카드가 하나씩 있습니다. 아직 프로파일을 등록하지 않은 설비에는 "분류 프로파일이 ' +
      '없습니다"라는 안내가 뜨고, 명령 전송 버튼 자체가 나타나지 않습니다.',
    ),
    ...shot('01-no-profile.png', '프로파일이 아직 없는 분류기 두 대 — 명령 전송 영역이 보이지 않음'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 프로파일에 넣을 값 이해하기')] }),
  ...section('입력 항목', [
    body('설비 카드의 입력줄에 다음 값을 채웁니다.'),
    bullet('Min Carton Gap (mm) — 화물과 화물 사이에 최소한 확보돼야 하는 간격입니다. 너무 좁으면 스캔이 겹치고, 너무 넓으면 처리량이 떨어집니다.'),
    bullet('Speed Mode — 이 설비의 기본 운전 방식입니다. FIXED는 지정한 속도로만 돌리는 방식, AUTO는 설비가 아래 범위 안에서 부하에 따라 스스로 조절하는 방식입니다.'),
    bullet('Min Speed / Max Speed — 이 설비에 허용되는 속도의 하한과 상한입니다. 이 범위를 벗어나는 속도 지시는 나중에 시스템이 거부합니다.'),
    bullet('Unit — 속도 단위입니다 (예: MPS, 초당 미터). 앞으로 이 설비에 보내는 모든 속도 지시가 같은 단위여야 합니다.'),
    bullet('Sensor Window (ms) — 센서가 화물 하나를 인식하는 데 쓰는 시간 폭입니다.'),
    ...shot('02-profile-form.png', '프로파일 입력값을 채운 상태 — 간격 150mm, 속도 0.5~2 MPS, 감지 윈도우 80ms'),
    body(
      '값이 확실하지 않다면 설비 제조사가 준 사양서의 기본값을 그대로 넣으세요. 나중에 언제든 ' +
      '고칠 수 있습니다(9장).',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 프로파일 등록')] }),
  ...section('하는 일', [
    body('값을 다 채웠으면 Create Profile 버튼을 누릅니다. 설비당 프로파일은 하나뿐이라, 등록 후에는 이 버튼이 Save Profile로 바뀝니다.'),
    body(
      '등록되면 카드 위쪽에 요약줄이 생깁니다 — "간격 ≥ 150mm / 속도 0.5–2 MPS / 기본 모드 FIXED / ' +
      '감지 윈도우 80ms / ACTIVE". 그리고 이때부터 DIVERT와 SET_SPEED 입력줄이 나타납니다.',
    ),
    ...shot('03-profile-created.png', '프로파일 등록 완료 — 요약줄이 생기고 명령 전송 영역이 열림'),
    body(
      'ACTIVE는 "이 기준을 지금 쓰고 있다"는 뜻입니다. 설비를 정비해야 해서 잠시 분류 명령을 막고 ' +
      '싶으면 프로파일 상태를 INACTIVE로 바꾸면 됩니다 — 그러면 그 설비로 가는 DIVERT/SET_SPEED가 ' +
      '모두 거부됩니다(9장).',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 속도 조정 (SET_SPEED)')] }),
  ...section('하는 일', [
    body('Speed Mode를 고르고 Dispatch SET_SPEED를 누릅니다.'),
    bullet('FIXED를 고르면 Speed Value 칸이 나타납니다. 프로파일에 등록한 하한~상한 사이 값만 받습니다.'),
    bullet('AUTO를 고르면 값을 넣지 않습니다. "이 범위 안에서 알아서 조절하라"는 지시만 설비로 나갑니다.'),
    body(
      '범위를 벗어난 값을 넣으면 명령이 만들어지지 않고 빨간 띠로 거부 사유가 나옵니다. ' +
      '예를 들어 상한이 2 MPS인 설비에 3.5를 넣으면 "speed_value 3.5 is outside the profile range ' +
      '0.5..2 MPS"가 표시됩니다. 실수로 라인을 과속시키는 사고를 화면 단계에서 막아 줍니다.',
    ),
    ...shot('04-speed-out-of-range.png', '프로파일 범위를 벗어난 속도 지시가 거부된 화면'),
    body(
      '단위(MPS 등)도 프로파일과 같아야 합니다. 다른 단위로 보내면 같은 방식으로 거부됩니다 — ' +
      '시스템은 단위를 자동 환산하지 않습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 슈트 배출 지시 (DIVERT)')] }),
  ...section('하는 일', [
    body('화물 한 건을 특정 슈트로 보내라는 지시입니다. 세 칸을 채우고 Dispatch DIVERT를 누릅니다.'),
    bullet('Target Chute — 목적지 슈트 번호입니다 (예: CHUTE-12).'),
    bullet('Item Identifier — 보낼 화물의 식별자입니다. 보통 카톤 바코드를 그대로 넣습니다.'),
    bullet('Expected Gap (mm) — 선택 항목입니다. 비워 두면 프로파일의 최소 간격을 기대값으로 씁니다.'),
    body(
      '두 필수 칸 중 하나라도 비어 있으면 거부됩니다. 명령이 만들어지면 카드 아래 "진행 중 분류 명령"에 ' +
      'DIVERT (PENDING)로 나타나고, 설비가 접수하면 상태가 바뀝니다.',
    ),
    ...shot('05-divert-dispatched.png', 'DIVERT 명령 전송 직후 — 진행 중 분류 명령 목록에 표시됨'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 오분류(MISROUTE)가 보고되면')] }),
  ...section('무슨 일이 일어나는가', [
    body(
      '설비는 지시를 수행한 뒤 결과를 스스로 되돌려 보고합니다. 운영자가 누를 버튼은 없습니다. ' +
      '엉뚱한 슈트로 나갔다면 오분류로 보고됩니다.',
    ),
    body(
      '화면을 새로고침하면 설비 카드 머리에 "최근 분류 결과: MISROUTE" 배지가 붙습니다. ' +
      '중요한 점은 설비 상태가 그대로라는 것입니다 — 라인은 멈추지 않았고 다음 화물을 계속 처리합니다.',
    ),
    ...shot('06-misroute-no-fault.png', '오분류 보고 후 — 결과 배지만 바뀌고 설비는 계속 가동 중'),
    body('WCS Monitor에서 보면 그 명령만 COMMAND_FAILED로 남아 있고, 장애 알림은 없습니다.'),
    ...shot('07-monitor-misroute.png', 'WCS Monitor — 명령은 실패로 기록됐지만 장애는 발생하지 않음'),
    body(
      '오분류 화물은 현장에서 사람이 회수해 다시 태우면 됩니다. 같은 슈트에서 오분류가 반복된다면 ' +
      '스캐너나 슈트 게이트 점검이 필요하다는 신호입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('7. 잼(JAM)이 보고되면')] }),
  ...section('시스템이 자동으로 하는 일', [
    body(
      '화물이 물리적으로 걸리면 설비가 잼을 보고합니다. 이때는 오분류와 달리 시스템이 스스로 ' +
      '다음을 수행합니다 — 아무도 장애를 신고하지 않아도 됩니다.',
    ),
    bullet('설비 상태를 FAULT(장애)로 바꿉니다.'),
    bullet('그 설비에 걸려 있던 다른 명령들도 모두 실패로 정리합니다 — 막힌 라인에 지시가 쌓이는 것을 막습니다.'),
    bullet('SORTATION_JAM 이라는 심각도 CRITICAL 장애를 새로 등록합니다.'),
    bullet('그 설비로 가는 새 명령을 더 이상 받지 않습니다.'),
    ...shot('08-jam-auto-fault.png', '잼 보고 직후 — 설비가 FAULT로 바뀌고 진행 중 명령이 모두 정리됨'),
    body('WCS Monitor에는 사람이 신고한 장애와 똑같은 모양으로 나타납니다.'),
    ...shot('09-monitor-jam-fault.png', 'WCS Monitor — 자동으로 등록된 SORTATION_JAM / CRITICAL 장애'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('8. 잼 해소하고 재가동')] }),
  ...section('하는 일', [
    body(
      '현장에서 걸린 화물을 제거한 뒤, WCS Monitor 화면에서 그 장애 줄에 해소 사유를 적고 ' +
      'Resolve Fault를 누릅니다. 이 작업은 현장을 확인한 사람만 할 수 있습니다 — 설비 쪽 시스템도, ' +
      '프로세스 자동화도 대신 눌러 줄 수 없습니다.',
    ),
    body('장애가 해소되면 설비는 IDLE(대기)로 돌아가고 장애 알림이 사라집니다.'),
    ...shot('10-jam-resolved.png', '장애 해소 후 — 알림이 사라지고 설비가 IDLE로 복귀'),
    body('WCS Sortation 화면으로 돌아오면 다시 명령을 보낼 수 있습니다. 아래는 재가동 뒤 AUTO 모드로 속도 제어를 설비에 맡긴 예입니다.'),
    ...shot('11-auto-speed-after-recovery.png', '재가동 후 AUTO 모드 SET_SPEED 전송'),
    body(
      '실패로 정리된 명령들은 되살아나지 않습니다. 아직 처리해야 할 화물이 남아 있다면 명령을 ' +
      '다시 보내야 합니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('9. 프로파일 수정과 권한')] }),
  ...section('값 고치기', [
    body(
      '요약줄 아래 입력값을 고치고 Save Profile을 누르면 반영됩니다. 화면 위에 저장 결과와 ' +
      '새 버전 번호가 뜹니다. 이미 나가 있는 명령은 새 기준으로 다시 검사하지 않습니다 — ' +
      '그런 경우 안내 문구가 함께 표시됩니다.',
    ),
    body('Profile Status를 INACTIVE로 바꾸면 그 설비로 가는 분류 명령이 전부 거부됩니다. 정비 중인 설비를 잠가 두는 용도입니다.'),
  ]),
  ...section('역할에 따라 화면이 다릅니다', [
    body(
      '프로파일을 고칠 수 있는 역할과 명령을 보낼 수 있는 역할이 완전히 같지는 않습니다. ' +
      '시스템 관리자(WMS_ADMIN)는 기준값을 관리할 수 있지만 설비에 직접 명령을 보내지는 않습니다 — ' +
      '그래서 그 역할로 보면 프로파일 입력줄만 있고 명령 버튼이 없으며, 화면에 그 이유가 안내됩니다.',
    ),
    ...shot('12-admin-profile-only.png', 'WMS_ADMIN 화면 — 프로파일 편집은 가능하고 명령 전송 영역은 없음'),
    ...shot('13-admin-profile-saved.png', '상한 속도를 2.5 MPS로 올려 저장한 결과'),
    body('세 역할(WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR) 어디에도 속하지 않으면 현황만 조회됩니다.'),
    ...shot('14-read-only-role.png', '권한이 없는 역할 — 입력줄 없이 현황만 조회됨'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- troubleshooting ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 표시되는 안내(파란 띠)와 오류(빨간 띠)의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['has no sortation profile',
      '그 설비에 아직 기준값이 없습니다. 먼저 프로파일을 등록하세요(3장).'],
    ['sortation profile for … is INACTIVE',
      '프로파일이 잠겨 있습니다. 정비가 끝났다면 Profile Status를 ACTIVE로 되돌리세요(9장).'],
    ['is outside the profile range',
      '지시한 속도가 그 설비의 허용 범위 밖입니다. 값을 범위 안으로 조정하거나, 범위 자체가 잘못됐다면 프로파일을 고치세요.'],
    ['speed_unit … does not match the profile unit',
      '속도 단위가 프로파일과 다릅니다. 시스템은 단위를 환산하지 않습니다 — 같은 단위로 입력하세요.'],
    ['DIVERT payload requires target_chute / item_identifier',
      '목적 슈트나 화물 식별자를 비워 두고 보냈습니다. 두 칸 모두 필수입니다.'],
    ['is only valid for SORTER/CONVEYOR equipment',
      '분류 명령을 분류기가 아닌 설비에 보내려 했습니다. 이 화면에는 SORTER/CONVEYOR만 나오므로 보통은 만날 일이 없습니다.'],
    ['already has a sortation profile',
      '설비당 프로파일은 하나뿐입니다. 새로 만들지 말고 Save Profile로 고치세요.'],
    ['is in FAULT and cannot accept new commands',
      '설비가 장애 상태입니다. WCS Monitor에서 장애를 먼저 해소하세요(8장).'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 사람이 먼저 프로파일을 바꿨습니다. 새로고침한 뒤 다시 시도하세요. 덮어쓰기 사고를 막기 위한 정상 동작입니다.'],
    ['FORBIDDEN: role cannot …',
      '현재 로그인한 역할에는 이 작업 권한이 없습니다. 오른쪽 위 역할 배지를 확인하고 권한이 있는 담당자에게 요청하세요.'],
    ['IN_FLIGHT_COMMANDS_NOT_REVALIDATED',
      '오류가 아닙니다. 프로파일을 고쳤지만 이미 나가 있는 명령에는 새 기준이 적용되지 않았다는 안내입니다.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/wcs-sortation-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: '고속 분류 제어 · 분류 프로파일/Divert/속도 조정 운영 매뉴얼', size: 18, color: '94A3B8' })],
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
