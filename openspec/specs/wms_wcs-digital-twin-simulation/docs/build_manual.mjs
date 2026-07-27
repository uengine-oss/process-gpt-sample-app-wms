// Builds the WCS 디지털 트윈/시뮬레이션 운영자 매뉴얼 (.docx) from the screenshots
// captured by frontend/playwright/e2e/wcs-simulation-flow.spec.ts.
//
//   npm install -g docx      # or a local `npm install docx`
//   node build_manual.mjs
//
// Same generator shape as the five build_manual.mjs before it
// (wms_wcs-equipment-control, wms_wes-material-flow-control,
// wms_wcs-sortation-logic, wms_wcs-bottleneck-routing,
// wms_wcs-sequential-dispatch) so the six manuals stay visually consistent.
// Every screenshot in this manual is a real frame from a passing Playwright run
// against a live local Supabase — nothing here is mocked up, and the state
// transitions shown were made by the real external worker process.

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
const OUT = path.resolve(HERE, 'wcs-digital-twin-simulation-operator-manual.docx')

// US Letter, 1" margins -> 9360 DXA of content width.
const CONTENT_DXA = 9360
// Screenshots are 1280x~1700 CSS px; scale to fit the text column (6.5in).
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
  // full-page captures of this screen are very tall; cap the height so a
  // single figure never eats more than one page.
  let w = IMG_W
  let h = Math.round((height / width) * IMG_W)
  const MAX_H = 780
  if (h > MAX_H) { w = Math.round((width / height) * MAX_H); h = MAX_H }
  return [
    new Paragraph({
      spacing: { before: 120, after: 60 },
      alignment: AlignmentType.CENTER,
      children: [
        new ImageRun({
          type: 'png',
          data: fs.readFileSync(abs),
          transformation: { width: w, height: h },
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
    children: [new TextRun({ text: 'WCS 디지털 트윈 · 시뮬레이션', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '설비 시뮬레이션 모드 · 타이밍 프로파일 · what-if 시나리오 운영 매뉴얼', size: 36, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 설비운영자(WCS_OPERATOR)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '창고관리자, 설비운영자, 데모/교육 진행자'],
    ['다루는 화면', 'WCS Simulation (/wcs/simulation) — 결과 확인은 WCS Equipment · WCS Monitor'],
    ['필요 권한',
      '시뮬레이션 모드 켜기/끄기: WMS_ADMIN, WAREHOUSE_MANAGER / 프로파일 등록·갱신: 여기에 ' +
      'WCS_OPERATOR 추가 / 시나리오 정의·실행: WMS_ADMIN, WAREHOUSE_MANAGER, PROCESS_AGENT — ' +
      '그 외 역할은 조회만'],
    ['선행 준비',
      '설비가 WCS Equipment 화면에 등록되어 있을 것 (별도 매뉴얼: WCS 자동화 설비 제어). ' +
      '그리고 외부 워커 프로세스가 떠 있을 것 — 2장 참고'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (wcs-simulation-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '창고 자동화 설비가 아직 들어오지 않았거나, 들어와 있어도 데모·교육·회귀 테스트 때문에 ' +
    '함부로 돌릴 수 없는 경우가 많습니다. 이 화면은 그럴 때 설비를 "가짜로" 세워 두고 ' +
    'WMS 쪽 흐름 전체를 실제처럼 굴려 보게 해 줍니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('무엇이 가짜이고 무엇이 진짜인가')] }),
  body(
    '오해를 먼저 없애야 합니다. 가짜인 것은 오직 하나 — "설비가 응답한다"는 사실뿐입니다. ' +
    '그 응답을 받은 뒤 WMS 안에서 일어나는 일은 전부 진짜입니다.',
  ),
  infoTable([
    ['구분', '내용'],
    ['가짜(시뮬레이션)',
      '설비가 몇 초 뒤에 응답할지, 성공할지 실패할지. 이것만 이 화면의 프로파일이 정합니다.'],
    ['진짜(실제 계약)',
      '명령 디스패치, 상태 전이(ACKNOWLEDGED → IN_PROGRESS → COMPLETED/FAILED), 작업지시 ' +
      '연동, 소터 잼의 자동 장애 승격, 팔레타이징 항목별 완료 전파, 감사 로그. 시뮬레이션 ' +
      '설비라고 해서 건너뛰는 것이 하나도 없습니다.'],
  ]),
  body(
    '이것이 중요한 이유는, 시뮬레이션으로 확인한 흐름이 실제 설비를 붙였을 때 그대로 ' +
    '동작한다는 뜻이기 때문입니다. 시뮬레이터는 설비 응답을 대신 만들어 줄 뿐, WMS의 ' +
    '판단 경로를 우회하지 않습니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('세 가지 개념')] }),
  infoTable([
    ['개념', '뜻'],
    ['시뮬레이션 모드 (Simulated)',
      '설비 한 대에 붙이는 켜고 끄는 스위치입니다. 켜면 그 설비의 명령을 워커가 대신 ' +
      '응답해 주고, 끄면 실제 게이트웨이나 사람 운영자의 몫으로 남습니다. 설비의 ' +
      '가동 상태(IDLE/RUNNING)는 이 스위치와 무관하게 그대로입니다.'],
    ['프로파일 (Profile)',
      '"얼마나 느리게, 얼마나 자주 실패할 것인가"입니다. 단계별 지연 범위(최소~최대)와 ' +
      '실패율·잼율로 이루어집니다. 등록하지 않아도 시뮬레이션은 동작합니다 — 그때는 ' +
      '시스템 기본값이 적용됩니다.'],
    ['시나리오 (Scenario)',
      '"이 설비 몇 대로 명령 N건을 처리하면 얼마나 걸릴까"를 묻는 계산입니다. 명령을 ' +
      '실제로 내보내지 않습니다 — 순수한 dry-run 산술입니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 1 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 화면 열기와 설비 목록 읽기')] }),
  ...section('하는 일', [
    body(
      '왼쪽 메뉴에서 WCS Simulation을 선택합니다. 맨 위 "설비 시뮬레이션 모드" 표에 ' +
      '창고의 모든 설비가 나오고, 각 줄이 지금 REAL인지 SIMULATED인지 보여 줍니다.',
    ),
    ...shot('01-simulation-board-real.png', '방금 등록한 TWIN-AGV-01은 아직 REAL 상태입니다'),
    body(
      '표에서 눈여겨볼 칸은 두 개입니다. Timing은 그 설비에 지금 적용되는 지연 범위이고, ' +
      'Source는 그 값이 어디서 왔는지를 알려 줍니다 — "기본값"이면 프로파일이 없다는 뜻, ' +
      '"등록 프로파일"이면 누군가 값을 정해 뒀다는 뜻입니다.',
    ),
  ]),
  ...section('Status와 Simulated는 다른 축입니다', [
    body(
      'Status는 설비가 지금 일하고 있는지(IDLE/RUNNING/FAULT)이고, Simulated는 그 설비의 ' +
      '응답을 누가 만들어 주는지입니다. 시뮬레이션을 켜도 Status는 손대지 않습니다 — ' +
      '가동 중인 설비를 시뮬레이션으로 바꿔도 그 설비가 갑자기 쉬게 되지는 않습니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 2 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 워커 프로세스 — 실제로 움직이는 것은 이 화면이 아닙니다')] }),
  ...section('반드시 알아야 할 것', [
    body(
      '이 화면은 "무엇을 시뮬레이션할지"와 "어떻게 시뮬레이션할지"만 정합니다. 명령을 ' +
      '실제로 ACKNOWLEDGED → IN_PROGRESS → COMPLETED로 밀어 주는 것은 화면이 아니라 ' +
      '별도로 떠 있는 외부 워커 프로세스입니다. 화면 위쪽 파란 안내 박스가 이 사실을 ' +
      '늘 알려 줍니다.',
    ),
    body(
      '워커가 꺼져 있으면 시뮬레이션 설비의 명령은 PENDING에서 멈춰 있습니다. 이것은 ' +
      '고장이 아니라 "아무도 응답하고 있지 않다"는 정직한 상태입니다.',
      { italics: true },
    ),
  ]),
  ...section('워커를 켜는 법', [
    body('저장소 루트에서 다음을 실행해 두면 됩니다. 새 서비스나 도커 이미지가 아니라 소스에서 바로 도는 프로세스입니다.'),
    body(
      'cd services/sample-app-wms/mcp\n' +
      '.venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --loop --interval 1',
      { font: 'Courier New', size: 19 },
    ),
    infoTable([
      ['실행 방식', '언제 쓰는가'],
      ['--loop --interval 1', '데모·교육 중 계속 켜 두는 평상시 방식입니다.'],
      ['--once', '한 번에 밀린 것을 전부 끝까지 처리하고 종료합니다. 테스트 스크립트에서 씁니다.'],
      ['--tick', '한 번만 폴링합니다 — 지금 도래한 것만 한 단계 밀고 종료합니다. 단계별로 관찰할 때 유용합니다.'],
    ]),
  ]),
  ...section('왜 굳이 별도 프로세스인가', [
    body(
      '설비 결과 보고는 WCS_GATEWAY 권한으로 로그인한 세션에서만 할 수 있습니다. 이 앱에 ' +
      '로그인한 창고관리자는 게이트웨이가 아니므로, 화면이 직접 결과를 보고하면 실제 설비 ' +
      '연동과 다른 지름길이 생깁니다. 워커는 실제 PLC/WCS 브리지와 똑같이 게이트웨이 ' +
      '계정으로 로그인해서 같은 문을 통과합니다.',
    ),
    bullet('워커를 껐다 켜도 진행 중이던 계획은 DB에 남아 있어 이어서 진행됩니다 — 중복 보고도, 유실도 없습니다.'),
    bullet('워커가 꺼져 있어도 사람 운영자가 기존 설비 화면에서 손으로 같은 명령을 처리할 수 있습니다.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 3 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 설비를 시뮬레이션으로 돌리기')] }),
  ...section('하는 일', [
    body('시뮬레이션하고 싶은 설비 줄의 Simulate 버튼을 누릅니다. 그것으로 끝입니다.'),
    ...shot('02-simulation-mode-on.png', 'SIMULATED로 바뀌었지만 상태는 여전히 IDLE, Source는 아직 "기본값"'),
    body(
      '바뀐 것은 Simulated 칸 하나뿐입니다. 프로파일을 아직 등록하지 않았으므로 Source는 ' +
      '"기본값"이고, 이 상태로도 시뮬레이션은 바로 동작합니다 — 시스템 기본값(ack 500ms~1.5s, ' +
      'progress 1.0s~3.0s, completion 2.0s~5.0s, 실패율 5%, 잼율 0%)이 적용됩니다.',
    ),
    bullet('되돌리려면 같은 자리의 Turn Off를 누릅니다.'),
    bullet('다른 사람이 먼저 바꿨다면 버전 충돌로 거부됩니다. Refresh 후 다시 시도하세요.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 4 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 타이밍 프로파일 정하기')] }),
  ...section('하는 일', [
    body(
      '"시뮬레이션 프로파일" 카드에서 설비를 고르고 단계별 지연(ms)과 실패율·잼율을 적은 뒤 ' +
      'Save Profile을 누릅니다. 프로파일이 없으면 등록, 있으면 갱신입니다 — 같은 버튼입니다.',
    ),
    ...shot('03-profile-form.png', '아주 빠른 프로파일(각 단계 100~200ms, 실패율 0)을 입력한 모습'),
    ...shot('04-profile-registered.png', '저장 후 Source가 "등록 프로파일"로 바뀌고 Timing 칸이 갱신됨'),
  ]),
  ...section('값을 어떻게 정하는가', [
    infoTable([
      ['칸', '뜻'],
      ['Ack min / max',
        '명령을 받고 "접수했다"고 답하기까지의 시간 범위입니다. 실제 값은 이 범위 안에서 무작위로 뽑힙니다.'],
      ['Progress min / max', '접수 후 "작업 시작"까지의 시간 범위입니다.'],
      ['Completion min / max', '작업 시작 후 종료 보고까지의 시간 범위입니다.'],
      ['Failure rate',
        '0~1 사이의 확률입니다. 1이면 항상 실패, 0이면 항상 성공. 데모에서는 0, 예외 처리 훈련에서는 1을 씁니다.'],
      ['Jam rate',
        'DIVERT(분류) 명령이 실패할 때 그 실패가 "잼(JAM)"이 될 확률입니다. 1로 두면 소터 잼의 ' +
        '자동 장애 승격까지 그대로 재현됩니다.'],
    ]),
    bullet('min이 max보다 크면 거부됩니다.'),
    bullet('실패율·잼율이 0~1 밖이면 거부됩니다.'),
    bullet('시뮬레이션 모드가 꺼진 설비에는 프로파일을 등록할 수 없습니다 — 먼저 3장을 하세요.'),
    body(
      '데모용으로 값을 아주 짧게(100~200ms) 잡으면 명령이 눈 깜짝할 사이에 끝나 관찰이 ' +
      '어렵습니다. 설명하면서 보여 줄 때는 오히려 기본값 정도가 보기 좋습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 5 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 명령을 보내고 결과를 확인하기')] }),
  ...section('하는 일', [
    body(
      '여기서부터는 이 화면을 떠납니다. 평소처럼 WCS Equipment 화면에서 그 설비에 명령을 ' +
      '보내면 됩니다. 명령을 보내는 사람은 그 설비가 시뮬레이션인지 알 필요도 없습니다.',
    ),
    body('워커가 켜져 있으면 몇 초 뒤 명령이 저절로 끝나 있습니다.'),
    ...shot('05-equipment-completed-by-worker.png', '아무도 게이트웨이를 건드리지 않았는데 명령이 완료되고 설비가 IDLE로 돌아옴'),
    body(
      'WCS Monitor 화면에는 단계별 이벤트가 그대로 남습니다 — COMMAND_ACKNOWLEDGED, ' +
      'COMMAND_PROGRESS, COMMAND_COMPLETED. 실제 설비가 보고했을 때와 똑같은 모양이며, ' +
      '이벤트 상세에 "시뮬레이션에서 나온 값"이라는 표시가 함께 붙습니다.',
    ),
    ...shot('06-monitor-completed-by-worker.png', 'WCS Monitor에 남은 완료 이벤트'),
  ]),
  ...section('진행 중인 계획 — 시뮬레이션이 블랙박스가 되지 않도록', [
    body(
      '워커가 명령을 처음 발견하면 각 단계의 목표 시각과 최종 결과를 그 자리에서 한 번만 ' +
      '굴려 "계획"으로 고정합니다. WCS Simulation 화면의 "진행 중인 계획" 표는 그 계획을 ' +
      '미리 보여 줍니다 — 즉, 끝나기 전에 이미 무엇으로 끝날지 알 수 있습니다.',
    ),
    body(
      '주사위를 한 번만 굴리는 데는 이유가 있습니다. 매 단계마다 다시 굴리면 워커를 껐다 ' +
      '켤 때마다 결과가 달라지기 때문입니다. 한 번 고정해 두면 워커가 몇 번 재시작되든 ' +
      '같은 명령은 같은 결말을 맞습니다.',
      { italics: true },
    ),
    body('명령이 끝나면 계획 줄은 사라집니다. 기록은 WCS Monitor의 이벤트 목록에 남습니다.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 6 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 일부러 실패시키기 — 예외 처리 훈련')] }),
  ...section('하는 일', [
    body(
      '실패율을 1로 바꾸고 저장하면, 그 뒤에 나가는 명령은 전부 실패로 끝납니다. ' +
      '장애 대응 절차를 훈련하거나 예외 흐름을 시연할 때 씁니다.',
    ),
    ...shot('07-failure-rate-1.png', '실패율을 1로 갱신한 직후'),
    body(
      '명령을 보내고 워커를 한 번만 폴링(--tick)시키면, "진행 중인 계획" 표에 아직 끝나지 ' +
      '않은 명령이 이미 FAILED 예정으로 표시됩니다.',
    ),
    ...shot('08-plan-preview-failed.png', '끝나기 전인데 Planned outcome이 이미 FAILED'),
    ...shot('09-monitor-simulated-failure.png', '실제로 COMMAND_FAILED로 종료된 이벤트'),
  ]),
  ...section('잼(JAM)은 한 걸음 더 갑니다', [
    body(
      '분류기(SORTER)에 DIVERT 명령을 보내면서 잼율을 1로 두면, 실패가 단순 실패가 아니라 ' +
      '"잼"으로 보고됩니다. 그러면 분류 계약이 자동으로 장애를 올리고 설비가 FAULT 상태가 ' +
      '됩니다 — 실제 잼이 났을 때와 똑같은 경로입니다. 이 자동 승격을 손으로 재현할 필요가 ' +
      '없다는 것이 시뮬레이션의 실질적인 이득입니다.',
    ),
  ]),
  ...section('시뮬레이션이 아닌 설비는 건드리지 않습니다', [
    body(
      '같은 창고에 시뮬레이션이 꺼진 설비가 있어도 워커는 그 설비의 명령을 절대 만지지 ' +
      '않습니다. 그 명령은 PENDING 그대로 남아 실제 게이트웨이나 사람을 기다립니다. ' +
      '실 설비와 가짜 설비를 한 창고에 섞어 둬도 안전한 이유입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 7 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('7. what-if 시나리오 — 명령 없이 계산만')] }),
  ...section('하는 일', [
    body(
      '"이 설비 몇 대로 명령 N건을 처리하면 얼마나 걸릴까"를 물어보는 기능입니다. ' +
      '이름, 명령 건수, 대상 설비를 고르고 Create Scenario를 누릅니다.',
    ),
    ...shot('10-scenario-form.png', '설비 2대에 명령 10건을 가정한 시나리오 입력'),
    ...shot('11-scenario-draft.png', '만들어진 직후에는 DRAFT — "아직 실행 전"입니다'),
    body('Run을 누르면 추정치가 계산됩니다. 여러 번 눌러도 되고, 실행할 때마다 새 기록이 쌓입니다.'),
    ...shot('12-scenario-projected.png', '10건 ÷ 2대 = 5회전, 예상 소요 20.1초, 예상 실패 5건'),
    ...shot('13-scenario-second-run.png', '두 번째 실행 — Runs가 2로 늘고 이전 추정치도 남아 있습니다'),
  ]),
  ...section('설비 명령은 단 한 건도 나가지 않습니다', [
    body(
      '이것이 시나리오의 핵심 성질입니다. Run을 아무리 눌러도 설비 명령 테이블에는 아무 ' +
      '변화가 없습니다. 순수한 계산이므로 운영 중인 창고에서도 마음대로 눌러 볼 수 있습니다.',
      { italics: true },
    ),
  ]),
  ...section('경고 문구를 반드시 읽으세요', [
    body('결과 아래 노란 경고는 이 추정치를 어디까지 믿어야 하는지를 알려 줍니다.'),
    infoTable([
      ['경고', '뜻'],
      ['DEFAULT_PROFILE_APPLIED',
        '그 설비에는 등록된 프로파일이 없어 시스템 기본값으로 계산했다는 뜻입니다. ' +
        '실제 설비 성능과 다를 수 있으니, 진지한 계획에 쓰려면 프로파일부터 등록하세요.'],
      ['OPTIMISTIC_ESTIMATE',
        '계산식은 단순히 "회전 수 × 1건 평균 시간"입니다. 대기 행렬, 재시도, 우선순위 ' +
        '역전을 전부 무시한 낙관적 근사치입니다 — 하한선으로 읽으세요.'],
    ]),
    bullet('명령 건수는 시스템이 세어 주지 않습니다. 운영자가 직접 넣는 값입니다.'),
    bullet('설비를 하나도 고르지 않거나 명령 건수를 0 이하로 넣으면 만들어지지 않습니다.'),
    bullet('Linked entity는 참고용 라벨입니다(예: dispatch_wave). 아무 계산에도 쓰이지 않습니다.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 8 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('8. 역할별로 보이는 것이 다릅니다')] }),
  ...section('설비운영자 (WCS_OPERATOR)', [
    body(
      '설비운영자는 프로파일 값은 조정할 수 있지만, 어떤 설비를 시뮬레이션할지 결정하거나 ' +
      '시나리오를 정의할 수는 없습니다. 그래서 Simulate / Turn Off / Create Scenario ' +
      '버튼이 아예 보이지 않습니다.',
    ),
    ...shot('14-operator-view.png', '설비운영자 화면 — Save Profile만 있고 모드 전환·시나리오 버튼이 없습니다'),
    body(
      '이 구분에는 뜻이 있습니다. "이 설비가 진짜냐 가짜냐"는 창고 운영 정책이고, ' +
      '"가짜라면 얼마나 느리냐"는 현장 조정이기 때문입니다.',
      { italics: true },
    ),
  ]),
  ...section('그 외 역할', [
    body('세 권한 중 아무것도 없는 역할은 현황만 볼 수 있고 입력 카드가 전혀 보이지 않습니다.'),
  ]),
  ...section('모든 변경은 기록됩니다', [
    body(
      '시뮬레이션 모드 전환, 프로파일 등록·갱신, 시나리오 정의·실행은 물론 워커가 만든 ' +
      '계획 수립과 단계 진행까지 전부 감사 로그에 남습니다. 워커가 남긴 기록의 행위자는 ' +
      'WCS_GATEWAY 계정이므로, "이 완료는 사람이 한 것인가 시뮬레이터가 한 것인가"를 ' +
      '나중에 구분할 수 있습니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 9 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('9. 이 기능이 하지 않는 일')] }),
  body('기대를 정확히 맞추기 위해, 지금 없는 것을 분명히 적어 둡니다.'),
  infoTable([
    ['없는 것', '설명'],
    ['3D 움직임·물리 모델',
      '설비가 어디를 어떻게 지나가는지는 계산하지 않습니다. "얼마 뒤 끝났다"만 만듭니다.'],
    ['PLC/필드버스 프로토콜',
      '실제 설비 통신 규약은 흉내 내지 않습니다. WMS 쪽 계약(RPC)만 사용합니다.'],
    ['결정론적 재현',
      '주사위는 계획을 세우는 순간 굴려지고 시드가 없습니다. 같은 시나리오를 두 번 돌리면 ' +
      '다른 값이 나올 수 있습니다. 진행 중인 명령 하나에 대해서는 고정되지만, 전체 실행을 ' +
      '똑같이 재현할 수는 없습니다.'],
    ['대기 행렬 모델',
      '시나리오 계산에 큐 대기·재시도·우선순위가 들어 있지 않습니다(7장 OPTIMISTIC_ESTIMATE).'],
    ['명령 건수 자동 산출',
      '시나리오의 명령 건수는 웨이브 등에서 자동으로 끌어오지 않고 운영자가 직접 넣습니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- FAQ ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 겪는 상황')] }),
  infoTable([
    ['증상', '원인과 대처'],
    ['명령이 PENDING에서 안 움직임',
      '가장 흔한 경우입니다. (1) 워커가 꺼져 있거나 (2) 그 설비의 시뮬레이션 모드가 꺼져 ' +
      '있습니다. 2장과 3장을 확인하세요.'],
    ['"is not in simulation mode — set is_simulated first"',
      '프로파일을 등록하려는 설비가 아직 REAL입니다. 먼저 Simulate를 누르세요.'],
    ['"already has a simulation profile — update it instead"',
      '이미 프로파일이 있습니다. 같은 Save Profile 버튼이 갱신도 하므로 그대로 다시 저장하면 됩니다.'],
    ['"every delay range needs min <= max"',
      '지연 범위의 최소가 최대보다 큽니다.'],
    ['"failure_rate must be between 0 and 1"',
      '실패율·잼율은 0~1 사이의 확률입니다. 퍼센트(예: 50)가 아니라 0.5로 적으세요.'],
    ['"expected version ... but found ..."',
      '다른 사람이 먼저 바꿨습니다. Refresh를 눌러 최신 상태를 받은 뒤 다시 시도하세요.'],
    ['Simulate 버튼이 안 보임',
      '현재 역할에 모드 전환 권한이 없습니다(8장). 창고관리자나 관리자로 다시 로그인하세요.'],
    ['"진행 중인 시뮬레이션 계획이 없습니다."',
      '오류가 아닙니다. 대기 중인 명령이 없거나 이미 전부 끝난 상태입니다.'],
    ['시나리오를 실행해도 설비가 안 움직임',
      '정상입니다. 시나리오는 계산만 하며 명령을 내보내지 않습니다(7장).'],
    ['추정 시간이 실제보다 짧음',
      'OPTIMISTIC_ESTIMATE 경고를 보세요. 대기·재시도를 무시한 하한선입니다.'],
  ]),

  new Paragraph({ spacing: { before: 400 }, children: [new TextRun({
    text:
      '이 매뉴얼의 모든 화면은 실제 자동화 테스트(wcs-simulation-flow.spec.ts)가 로컬 ' +
      'Supabase를 상대로 돌면서 캡처한 것이며, 화면에 보이는 상태 전이는 실제 외부 워커 ' +
      '프로세스가 만든 것입니다. 계약의 상세 규칙과 검증 결과는 ' +
      'openspec/specs/wms_wcs-digital-twin-simulation/ 아래 spec.md와 e2e/README.md를 ' +
      '참고하세요.',
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
        children: [new TextRun({ text: 'WCS 디지털 트윈/시뮬레이션 · 시뮬레이션 모드/프로파일/what-if 시나리오 운영 매뉴얼', size: 18, color: '94A3B8' })],
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
