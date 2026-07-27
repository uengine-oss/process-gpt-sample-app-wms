// Builds the 지능형 라우팅/병목 해소 운영자 매뉴얼 (.docx) from the screenshots
// captured by frontend/playwright/e2e/wcs-routing-flow.spec.ts.
//
//   npm install -g docx      # or a local `npm install docx`
//   node build_manual.mjs
//
// Same generator shape as the three build_manual.mjs before it
// (wms_wcs-equipment-control, wms_wes-material-flow-control,
// wms_wcs-sortation-logic) so the four manuals stay visually consistent. Every screenshot in this manual is a real
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
const OUT = path.resolve(HERE, 'wcs-bottleneck-routing-operator-manual.docx')

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
    children: [new TextRun({ text: '지능형 라우팅 · 병목 해소', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '설비 부하 감시 · 병목 회피 · 강제 제외 운영 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 설비운영자(WCS_OPERATOR)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '창고관리자, 설비운영자'],
    ['다루는 화면', 'WCS Routing (/wcs/routing), 일부 WES Dispatch (/wes/dispatch)'],
    ['필요 권한', '임계값 정책: WMS_ADMIN, WAREHOUSE_MANAGER / 강제 제외·해제: 여기에 WCS_OPERATOR 추가 (그 외 역할은 조회만)'],
    ['선행 준비', '설비가 WCS Equipment 화면에 등록되어 있을 것 (별도 매뉴얼: WCS 자동화 설비 제어). 업무 오더 등록은 WES Dispatch 매뉴얼 참고'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (wcs-routing-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '창고에 같은 종류의 설비가 여러 대 있으면, 새 작업을 어느 설비에 줄지는 시스템이 자동으로 ' +
    '고릅니다. 이 매뉴얼은 그 자동 선택이 "지금 상태가 좋지 않은 설비"를 피해 가도록 만드는 ' +
    '화면(WCS Routing)의 사용법을 설명합니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('두 가지 신호를 봅니다')] }),
  bullet(
    '큐 길이 — 그 설비에 아직 끝나지 않은 명령이 몇 건 쌓여 있는가. "지금 일이 몰리고 있다"는 뜻입니다.',
  ),
  bullet(
    '최근 장애 건수 — 최근 30분 안에 그 설비에서 장애가 몇 번 났는가. 이미 고쳐진 장애도 셉니다. ' +
    '"요즘 불안정하다"는 뜻입니다.',
  ),
  body(
    '둘 중 하나라도 정해 둔 문턱값을 넘으면 그 설비에 "병목" 표시가 붙습니다. 이 판정은 어딘가에 ' +
    '저장돼 있는 상태가 아니라 화면을 열 때마다 그 자리에서 다시 계산한 값입니다 — 그래서 항상 ' +
    '"지금" 기준이고, 상황이 나아지면 새로고침만 해도 표시가 사라집니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('"병목"과 "강제 제외"는 다릅니다')] }),
  infoTable([
    ['구분', '뜻과 결과'],
    ['병목 (자동 판정)',
      '후순위로 밀립니다. 다른 멀쩡한 설비가 있으면 그쪽에 일이 갑니다. 하지만 다른 후보가 하나도 ' +
      '없으면 병목 설비라도 씁니다 — 작업이 무기한 대기하는 것보다 낫기 때문입니다.'],
    ['강제 제외 (사람이 지정)',
      '절대 배정하지 않습니다. 그 설비가 유일한 후보여도 선택되지 않고, 업무 오더는 대기(QUEUED) ' +
      '상태로 남습니다. 계획 정비처럼 "지금 이 설비는 손대면 안 된다"는 의도를 표현할 때 씁니다.'],
  ]),
  body(
    '헷갈리면 이렇게 기억하세요 — 병목은 시스템이 붙이는 "가급적 피하자" 표시, 강제 제외는 사람이 ' +
    '내리는 "쓰지 마라" 지시입니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('작업 순서')] }),
  infoTable([
    ['순서', '무엇을'],
    ['1. 현황 보기', '이 매뉴얼 1장. 어느 설비가 어떤 상태인지 한 화면에서 확인합니다.'],
    ['2. 임계값 조정', '이 매뉴얼 3장. 설비 유형별로 문턱값을 정합니다. 하지 않아도 기본값으로 동작합니다.'],
    ['3. 강제 제외', '이 매뉴얼 4장. 정비 등의 이유로 특정 설비를 빼 둡니다.'],
    ['4. 결과 확인', '이 매뉴얼 5~7장. 새 작업이 실제로 어디로 갔는지 WES Dispatch에서 확인합니다.'],
    ['5. 복귀', '이 매뉴얼 8장. 정비가 끝나면 제외를 해제합니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- steps ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 화면 열기와 읽는 법')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴에서 WCS Routing을 선택합니다. 이 창고에 등록된 설비가 모두 카드로 나옵니다.'),
    body('화면 맨 위 파란 버튼 옆에는 요약이 있습니다 — "병목 n대 / 강제 제외 n대". 오늘 라인 상태를 한눈에 보는 숫자입니다.'),
    body('설비 카드 한 줄은 이렇게 읽습니다.'),
    bullet('큐 0 / 3 — 지금 쌓인 미종결 명령이 0건, 병목 판정 문턱값이 3건이라는 뜻입니다.'),
    bullet('최근 장애 0 / 1 — 최근 30분 내 장애가 0건, 문턱값이 1건입니다.'),
    bullet('최근 완료 0 — 최근 30분 내 끝낸 명령 수입니다. 판정에는 쓰지 않고 참고용으로만 보여 줍니다.'),
    bullet('임계값 출처 — 이 설비에 적용된 문턱값이 등록된 정책에서 왔는지, 시스템 기본값인지 알려 줍니다.'),
    bullet('배정 가능 / 배정 불가 — 지금 이 설비가 새 작업을 받을 수 있는 상태인지입니다.'),
    ...shot('01-clean-board.png', '아무 문제 없는 상태 — 세 대 모두 병목 표시 없이 배정 가능'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 병목 표시가 붙는 순간')] }),
  ...section('무슨 일이 일어나는가', [
    body(
      '아래는 ROUTE-E2E-02 설비에서 30분 안에 장애가 두 번 나고 두 번 다 현장에서 해소된 뒤의 ' +
      '화면입니다. 설비 자체는 지금 멀쩡히 대기(IDLE) 중이고 밀린 명령도 없습니다 — 그런데도 ' +
      '"병목" 배지가 붙었습니다.',
    ),
    body(
      '이유는 카드에 그대로 적혀 있습니다: "병목 사유: 장애 잦음 (FAULT_FREQUENCY_EXCEEDED)". ' +
      '고쳐졌더라도 최근에 두 번이나 섰다는 사실 자체가 신호이기 때문입니다.',
    ),
    ...shot('02-bottleneck-detected.png', '최근 장애가 잦아 병목으로 판정된 설비 — 상태는 IDLE, 배정은 여전히 가능'),
    body(
      '배지 옆의 "배정 가능"이 그대로 남아 있는 점에 주목하세요. 병목은 금지가 아니라 후순위입니다. ' +
      '다른 후보가 없으면 이 설비가 선택됩니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 임계값 조정하기')] }),
  ...section('언제 조정하나', [
    body(
      '설비 종류마다 "정상"의 기준이 다릅니다. 스태커 크레인(SRM)은 한 번에 하나씩 순차 처리하니 ' +
      '큐가 2~3건만 쌓여도 늦어지지만, AGV는 여러 대가 병렬로 도니 같은 숫자가 아무 문제가 아닐 수 ' +
      '있습니다. 그래서 문턱값은 설비 유형별로 따로 정합니다.',
    ),
    body(
      '화면 위쪽 "병목 판정 임계값" 표에서 설비 유형을 고르고 두 숫자를 넣은 뒤 Register Policy를 ' +
      '누릅니다. 등록하지 않아도 됩니다 — 정책이 없는 유형에는 시스템 기본값(큐 3 / 장애 1)이 ' +
      '적용되고 판정은 그대로 동작합니다.',
    ),
    body(
      '아래는 AGV의 장애 문턱값을 3으로 올린 결과입니다. 장애 2건은 이제 3에 못 미치므로 같은 ' +
      '설비의 병목 표시가 사라졌습니다 — 판정이 마법이 아니라 단순 비교라는 것을 보여 줍니다.',
    ),
    ...shot('03-policy-raises-threshold.png', '장애 문턱값을 3으로 올리자 병목 표시가 사라짐'),
    body('문턱값을 2로 되돌리면 다시 붙습니다. 저장은 Save Policy 버튼입니다.'),
    ...shot('04-policy-restored.png', '문턱값을 2로 되돌려 병목 표시가 복귀'),
    body(
      '관찰 윈도우(최근 30분)는 고정이며 화면에서 바꿀 수 없습니다. 바꿀 수 있는 것은 문턱값 ' +
      '두 개뿐입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 설비를 강제로 빼 두기')] }),
  ...section('하는 일', [
    body(
      '정비 예정이거나 현장 점검이 필요한 설비는 자동 배정에서 아예 빼 둘 수 있습니다. ' +
      '설비 카드의 입력칸에 사유를 적고 Exclude from Routing을 누릅니다.',
    ),
    body(
      '사유는 필수입니다. 나중에 "이거 왜 빠져 있지?"라고 묻는 사람이 반드시 생기기 때문에, ' +
      '시스템은 빈 사유를 받지 않습니다.',
    ),
    ...shot('05-manual-exclusion.png', '계획 정비를 사유로 강제 제외한 설비 — 배정 불가로 바뀜'),
    body(
      '제외된 설비는 빨간 상자로 표시되고 "배정 불가"가 됩니다. 같은 설비를 한 번 더 제외할 수는 ' +
      '없습니다 — 이미 걸려 있으니 먼저 해제해야 합니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 새 작업이 병목을 피해 갑니다')] }),
  ...section('확인하는 법', [
    body(
      '여기서부터가 이 기능의 실제 효과입니다. WES Dispatch 화면에서 평소처럼 업무 오더를 ' +
      '만들면 됩니다 — 라우팅을 위해 따로 눌러야 할 버튼은 없습니다.',
    ),
    body(
      '아래 상황은 후보가 두 대입니다: 멀쩡한 ROUTE-E2E-01과 병목 표시가 붙은 ROUTE-E2E-02. ' +
      '(세 번째 설비는 4장에서 강제 제외해 뒀습니다.) 업무 오더는 멀쩡한 쪽으로 갔습니다.',
    ),
    ...shot('06-work-order-avoids-bottleneck.png', '업무 오더가 병목 설비를 피해 멀쩡한 설비로 배정됨'),
    body(
      'Equipment Command 칸에 어느 설비로 나갔는지 그대로 적혀 있습니다. 이것이 병목 감지가 ' +
      '실제로 반영됐다는 유일하고 확실한 증거입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 다른 후보가 없으면 병목 설비도 씁니다')] }),
  ...section('왜 그렇게 동작하나', [
    body(
      '5장에서 멀쩡한 설비가 일을 받아 바빠졌습니다. 이 상태에서 업무 오더를 하나 더 만들면 ' +
      '남은 후보는 병목 설비 하나뿐입니다.',
    ),
    body(
      '이때 시스템은 그 병목 설비에 작업을 배정합니다. 조금 불안한 설비라도 돌리는 편이, ' +
      '업무 오더를 기약 없이 세워 두는 것보다 낫다는 판단입니다.',
    ),
    ...shot('07-fallback-to-bottleneck.png', '다른 후보가 없어 병목 설비가 선택된 화면'),
    body(
      '이 동작이 마음에 들지 않는다면 — 즉 정말로 그 설비를 쓰고 싶지 않다면 — 병목 표시에 ' +
      '기대지 말고 4장의 강제 제외를 쓰세요. 그것이 두 기능을 나눠 둔 이유입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('7. 강제 제외된 설비는 끝까지 쓰지 않습니다')] }),
  ...section('무슨 일이 일어나는가', [
    body(
      '이제 남은 설비는 4장에서 강제 제외해 둔 한 대뿐입니다. 업무 오더를 하나 더 만들어 보면 ' +
      '결과가 6장과 완전히 다릅니다.',
    ),
    body(
      '업무 오더는 대기(QUEUED) 상태로 남고, 화면 위에 "NO_EQUIPMENT_AVAILABLE"(가용 설비 없음) ' +
      '안내가 뜹니다. 제외된 설비에는 명령이 단 한 건도 나가지 않습니다.',
    ),
    ...shot('08-excluded-machine-never-used.png', '강제 제외된 설비만 남자 업무 오더가 대기 상태로 유지됨'),
    body(
      '대기 중인 업무 오더는 사라지지 않습니다. 설비가 다시 가용해지면 Retry 버튼으로 배정을 ' +
      '재시도할 수 있습니다(8장).',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('8. 정비가 끝나면 되돌리기')] }),
  ...section('하는 일', [
    body(
      'WCS Routing 화면의 빨간 상자에서 Clear Exclusion을 누르면 제외가 해제됩니다. 즉시 ' +
      '"배정 가능"으로 돌아옵니다 — 재계산을 기다릴 필요가 없습니다.',
    ),
    ...shot('09-exclusion-cleared.png', '제외 해제 직후 — 곧바로 배정 가능 상태로 복귀'),
    body(
      '그다음 WES Dispatch에서 대기 중이던 업무 오더의 Retry를 누르면, 방금 복귀한 설비로 ' +
      '배정됩니다.',
    ),
    ...shot('10-retry-uses-recovered-machine.png', '복귀한 설비로 대기 중이던 업무 오더가 재배정됨'),
    body(
      '해제해도 기록은 지워지지 않습니다. 누가 언제 왜 뺐고 누가 언제 되돌렸는지가 그대로 남습니다 — ' +
      '나중에 "그날 왜 그 라인만 안 돌았지?"를 되짚을 수 있습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('9. 역할에 따라 화면이 다릅니다')] }),
  ...section('두 가지 권한이 따로 있습니다', [
    body(
      '문턱값을 정하는 일과 설비를 라인에서 빼는 일은 성격이 다릅니다. 앞은 창고 전체 운영 기준을 ' +
      '바꾸는 일이고, 뒤는 지금 이 설비 한 대에 대한 현장 판단입니다. 그래서 권한도 나눠 뒀습니다.',
    ),
    infoTable([
      ['역할', '할 수 있는 일'],
      ['WMS_ADMIN / WAREHOUSE_MANAGER', '임계값 정책 등록·수정, 강제 제외·해제, 조회'],
      ['WCS_OPERATOR', '강제 제외·해제, 조회 (임계값은 바꿀 수 없음)'],
      ['그 외 역할', '조회만'],
    ]),
    body(
      '설비운영자(WCS_OPERATOR)로 로그인하면 임계값 표가 읽기 전용이 되고, 화면에 그 이유가 ' +
      '노란 띠로 안내됩니다. 숨기지 않고 알려 줍니다.',
    ),
    ...shot('11-operator-exclusion-only.png', 'WCS_OPERATOR 화면 — 제외는 가능하고 임계값 편집 버튼은 없음'),
  ]),
  ...section('이미 나가 있는 명령은 멈추지 않습니다', [
    body(
      '작업이 진행 중인 설비를 제외하면, 제외는 "앞으로 새 작업을 주지 않겠다"는 뜻일 뿐 이미 ' +
      '나가 있는 명령을 취소하지는 않습니다. 그런 경우 안내에 ' +
      'IN_FLIGHT_COMMANDS_NOT_CANCELLED가 함께 표시됩니다.',
    ),
    ...shot('12-exclusion-warns-in-flight.png', '진행 중 명령이 있는 설비를 제외했을 때의 안내'),
    body(
      '지금 당장 멈춰야 하는 상황이라면 WCS Monitor 화면에서 해당 명령을 취소하거나 장애로 ' +
      '올려야 합니다 — 제외만으로는 멈추지 않습니다.',
      { italics: true },
    ),
    body('두 권한 어디에도 속하지 않는 역할은 현황만 조회됩니다.'),
    ...shot('13-read-only-role.png', '권한이 없는 역할 — 입력칸과 버튼 없이 현황만 조회됨'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- troubleshooting ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 표시되는 안내(파란 띠)와 오류(빨간 띠)의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['NO_EQUIPMENT_AVAILABLE',
      '조건에 맞는 가용 설비가 없어 업무 오더가 대기 상태로 남았습니다. 강제 제외를 걸어 둔 설비가 ' +
      '있는지 먼저 확인하세요 — 병목 표시만으로는 이 메시지가 나오지 않습니다.'],
    ['IN_FLIGHT_COMMANDS_NOT_CANCELLED',
      '오류가 아닙니다. 제외는 됐지만 이미 나가 있는 명령은 그대로 진행된다는 안내입니다(9장).'],
    ['is already excluded from routing',
      '그 설비에는 이미 활성 제외가 걸려 있습니다. 새로 걸지 말고 기존 제외를 해제하세요.'],
    ['reason is required',
      '제외 사유를 비워 두고 눌렀습니다. 사유는 필수입니다.'],
    ['a routing policy for … already exists',
      '그 설비 유형에는 이미 정책이 있습니다. 새로 만들지 말고 Save Policy로 고치세요.'],
    ['queue_depth_threshold must be greater than 0',
      '문턱값은 1 이상이어야 합니다. 0이나 음수는 받지 않습니다(장애 문턱값도 같습니다).'],
    ['nothing to update',
      '두 문턱값을 모두 비운 채 저장을 눌렀습니다. 하나 이상은 값이 있어야 합니다.'],
    ['is not ACTIVE (status=CLEARED)',
      '이미 해제된 제외를 다시 해제하려 했습니다. 새로고침하면 상태가 갱신됩니다.'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 사람이 먼저 같은 항목을 바꿨습니다. 새로고침한 뒤 다시 ' +
      '시도하세요. 덮어쓰기 사고를 막기 위한 정상 동작입니다.'],
    ['FORBIDDEN: role cannot manage wcs routing policies',
      '현재 역할에는 임계값을 바꿀 권한이 없습니다. 강제 제외는 가능할 수 있으니 오른쪽 위 역할 ' +
      '배지를 확인하세요(9장).'],
    ['FORBIDDEN: role cannot exclude equipment from routing',
      '현재 역할에는 제외 권한 자체가 없습니다. 권한이 있는 담당자에게 요청하세요.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('알아 두면 좋은 한계')] }),
  bullet(
    '병목 판정에는 이력이 없습니다. "이 설비가 몇 시부터 병목이었나"는 이 화면으로 알 수 없습니다 — ' +
    '항상 "지금" 기준입니다.',
  ),
  bullet(
    '큐가 쌓인 설비는 이미 가동 중(RUNNING)이라 신규 작업 후보에서 빠집니다. 그래서 실제 배정을 ' +
    '바꾸는 신호는 사실상 "장애 잦음" 쪽이고, "큐 적체" 표시는 어디서 일이 밀리는지 알려 주는 ' +
    '모니터링 용도입니다.',
  ),
  bullet(
    '이 기능은 설비 A 대신 설비 B를 고르는 것까지만 합니다. 컨베이어 분기점을 다시 계산하는 ' +
    '물리적 경로 재설정은 하지 않습니다.',
  ),
  bullet(
    '문턱값은 사람이 정합니다. 과거 데이터를 보고 시스템이 알아서 학습하지 않습니다.',
  ),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/wcs-routing-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: '지능형 라우팅/병목 해소 · 설비 부하 감시/병목 회피/강제 제외 운영 매뉴얼', size: 18, color: '94A3B8' })],
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
