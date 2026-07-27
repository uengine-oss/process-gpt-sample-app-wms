// Builds the 인력 관리 운영자 매뉴얼 (.docx) from the screenshots captured by
// frontend/playwright/e2e/labor-flow.spec.ts.
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
const OUT = path.resolve(HERE, 'labor-management-operator-manual.docx')

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
    children: [new TextRun({ text: '인력 관리', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '운영자 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '현장 작업자 · 창고관리자(WAREHOUSE_MANAGER)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '입고담당자·품질검사자 등 현장 작업자, 창고관리자'],
    ['다루는 화면', 'Labor (/labor)'],
    ['필요 권한',
      '작업 시작·완료·취소: INBOUND_OPERATOR, QUALITY_INSPECTOR, WAREHOUSE_MANAGER, WMS_ADMIN, PROCESS_AGENT (본인 명의만) / ' +
      '창고 전체 생산성·리더보드 열람과 인력 수요 추정: WAREHOUSE_MANAGER, WMS_ADMIN'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (labor-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 매뉴얼은 현장 작업을 시작하고 끝낼 때 그 사실을 화면에 남기는 방법, 그렇게 쌓인 기록이 ' +
    '생산성 집계와 리더보드로 어떻게 보이는지, 그리고 관리자가 그 숫자로 필요한 인원을 어떻게 ' +
    '가늠하는지를 순서대로 설명합니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('왜 작업 시간을 기록하나')] }),
  body(
    '입고·검수·적치 화면은 "무엇이 처리되었는가"를 기록합니다. 그러나 "그 일을 누가, 얼마나 걸려, ' +
    '몇 건 처리했는가"는 어디에도 남지 않습니다. 그 답이 없으면 내일 몇 명이 필요한지, 어느 작업이 ' +
    '병목인지, 새로 온 사람이 익숙해지고 있는지를 감으로만 이야기하게 됩니다.',
  ),
  body(
    'Labor 화면은 그 빈칸을 채웁니다. 작업을 시작할 때 한 번, 끝낼 때 한 번 누르면 그 사이 시간이 ' +
    '자동으로 계산되어 남습니다. 시간은 시스템이 직접 찍으므로 사람이 적어 넣거나 고칠 수 없습니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('내 기록은 누가 볼 수 있나')] }),
  body(
    '이 화면이 다루는 것은 개인의 업무 수행 기록입니다. 그래서 다른 화면들보다 열람 범위가 좁게 ' +
    '잠겨 있습니다.',
  ),
  bullet('작업자 본인 — 자기 기록만 봅니다. 옆자리 동료의 처리 건수도, 평균 시간도, 진행 중인 작업도 보이지 않습니다.'),
  bullet('창고관리자(WAREHOUSE_MANAGER) / 시스템관리자(WMS_ADMIN) — 담당 창고 안 모든 작업자의 기록을 봅니다.'),
  body(
    '이 제한은 화면이 골라서 숨기는 것이 아니라 데이터베이스가 애초에 내주지 않는 것입니다. ' +
    '주소를 직접 입력하거나 다른 경로로 접근해도 결과는 같습니다.',
    { italics: true },
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('다른 사람 이름으로는 기록할 수 없습니다')] }),
  body(
    '작업 기록은 언제나 로그인한 본인 명의로 남습니다. 화면에 "누구 대신 기록" 같은 입력란이 없는 ' +
    '것은 실수가 아니라 의도입니다 — 이 숫자가 생산성 비교와 인력 계획의 근거로 쓰이기 때문에, ' +
    '남의 이름으로 기록할 수 있으면 그 근거가 통째로 무너집니다.',
  ),
  body(
    '예외는 시스템관리자(WMS_ADMIN) 한 명뿐입니다. 오프라인으로 일한 작업자의 기록을 나중에 대신 ' +
    '입력하거나, 잘못 남은 기록을 정정하는 용도입니다. 이때도 기록의 주인은 실제 작업자이고, ' +
    '역할 표기도 그 작업자의 역할로 남습니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('작업 유형 고르는 법')] }),
  infoTable([
    ['유형', '언제 고르나'],
    ['RECEIVING', '입고 물품을 내리고 수량을 확인하는 작업'],
    ['QUALITY_INSPECTION', '입고품의 품질을 검사하는 작업'],
    ['PUTAWAY', '합격 물품을 보관 위치로 옮기는 적치 작업'],
    ['DISPOSITION', '불합격 물품을 폐기 등으로 처분하는 작업'],
    ['OTHER', '위 넷에 해당하지 않는 작업. 이 유형을 고르면 Activity Label(설명)을 반드시 적어야 합니다 — 적지 않으면 저장되지 않습니다.'],
  ]),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('작업 상태 읽는 법')] }),
  infoTable([
    ['상태', '의미'],
    ['IN_PROGRESS', '시작만 하고 아직 닫지 않은 작업입니다. "진행 중인 작업" 표에 남아 있습니다.'],
    ['COMPLETED', '완료했습니다. 처리 시간과 처리 수량이 확정되어 모든 집계에 들어갑니다.'],
    ['CANCELLED', '취소했습니다. 완료 건수·처리 시간·리더보드·수요 추정 어디에도 들어가지 않습니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 1 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 작업 시작하기')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴 WMS 그룹에서 Labor를 선택하면 이 화면이 열립니다.'),
    body(
      '처음 열었을 때 "진행 중인 작업"이 비어 있는 것이 정상입니다. 아래 화면은 동료가 지금 품질 검사 ' +
      '작업을 하나 열어 둔 상태에서 작업자가 접속한 것인데, 그 행이 목록에 보이지 않습니다 — ' +
      '본인 기록만 보이는 규칙이 여기서부터 적용되고 있습니다.',
    ),
    ...shot('01-worker-empty-board.png', '작업자가 처음 접속한 Labor 화면 (동료의 진행 중 작업은 보이지 않는다)'),
    body('상단 "작업 시작" 카드에서 두 가지를 정합니다.'),
    bullet('Activity Type — 지금 시작하는 작업의 종류입니다. OTHER를 고르면 Activity Label이 필수입니다.'),
    bullet('Activity Label — 나중에 목록에서 알아볼 수 있는 짧은 설명입니다 (예: 오전 입고 검수). OTHER가 아니면 비워 두어도 됩니다.'),
    body('Start Activity 버튼을 누르면 그 순간이 시작 시각으로 찍힙니다.'),
    ...shot('02-activity-started.png', '작업이 시작되어 진행 중 목록에 올라온 상태 (IN_PROGRESS)'),
  ]),
  ...section('확인할 점', [
    bullet('행의 Actor 열이 "나"로 표시되고 Role 열에 내 역할이 찍힙니다. 이 역할은 시작 시점의 것으로 고정되므로, 나중에 직무가 바뀌어도 지난 기록의 통계가 흔들리지 않습니다.'),
    bullet('Started 열이 서버 시각입니다. 내가 적어 넣는 값이 아닙니다.'),
    bullet('작업을 시작해도 입고·검수·적치 문서는 전혀 바뀌지 않습니다. 이 화면은 시간을 재는 계측 장치일 뿐이고, 실제 업무는 각자의 화면에서 그대로 처리합니다.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 2 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 작업 완료하기')] }),
  ...section('하는 일', [
    body(
      '일이 끝나면 해당 행의 수량 칸에 처리한 건수를 적고 Complete를 누릅니다. 완료 시각이 찍히면서 ' +
      '시작 시각과의 차이가 처리 시간으로 계산됩니다.',
    ),
    ...shot('03-activity-completed.png', '수량 48을 기록하고 완료한 직후 — 12분 30초가 집계에 반영되었다'),
    body(
      '완료된 작업은 "진행 중인 작업" 표에서 사라지고 아래 "생산성 집계"에 나타납니다. 위 화면에서는 ' +
      '완료 1건, 합계·평균 처리 시간 12m 30s, 처리 수량 48로 잡혔습니다.',
    ),
  ]),
  ...section('수량을 꼭 적어야 하나요', [
    body(
      '비워 두고 완료해도 저장은 됩니다. 다만 그 작업은 인력 수요 추정의 표본이 되지 못합니다 — ' +
      '추정이 "처리 수량 ÷ 처리 시간"으로 계산되기 때문입니다. 수량 없이 완료하면 화면이 그 사실을 ' +
      '알려 줍니다.',
    ),
    body(
      '한 줄 요약: 시간만 남기면 "얼마나 오래 걸렸나"까지만 알 수 있고, 수량까지 남겨야 ' +
      '"몇 명이 필요한가"를 계산할 수 있습니다.',
      { italics: true },
    ),
  ]),
  ...section('버전이 어긋났다는 오류가 나면', [
    body(
      '내가 화면을 열어 둔 사이에 관리자가 같은 기록을 먼저 손댔다는 뜻입니다. Refresh를 누르고 다시 ' +
      '시도하세요. 덮어쓰기 사고를 막기 위한 정상 동작입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 3 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 잘못 시작한 작업 취소하기')] }),
  ...section('하는 일', [
    body(
      '실수로 시작했거나 다른 일로 재배정되어 실제로는 하지 않은 작업은 Complete가 아니라 Cancel로 ' +
      '닫습니다. 해당 행의 Cancel 버튼을 누르면 됩니다.',
    ),
    ...shot('04-cancelled-excluded.png', '한 시간 동안 열려 있던 작업을 취소한 직후 — 집계 숫자는 그대로다'),
  ]),
  ...section('왜 완료로 닫으면 안 되나', [
    body(
      '위 화면에서 취소된 작업은 한 시간 동안 열려 있었습니다. 그것을 완료로 닫았다면 그 한 시간이 ' +
      '처리 시간에 더해져 평균이 크게 늘어나고, 실제로는 하지 않은 일이 처리 건수에 잡혔을 것입니다. ' +
      '취소로 닫았기 때문에 완료 1건, 수량 48이라는 숫자가 그대로 남았습니다.',
    ),
    body(
      '취소된 작업은 완료 건수, 평균·합계 처리 시간, 리더보드, 인력 수요 추정 어디에도 들어가지 ' +
      '않습니다. 기록 자체는 남아 있으므로 "언제 무엇을 왜 중단했는지"는 나중에 확인할 수 있습니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 4 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 작업자가 보는 내 생산성')] }),
  ...section('하는 일', [
    body(
      '화면 가운데 기간 카드에서 집계 시작일과 종료일을 고르면, 그 기간에 완료한 작업이 날짜·작업 ' +
      '유형별로 정리되어 나옵니다. 리더보드 정렬 기준(Leaderboard Metric)도 여기서 바꿉니다.',
    ),
    ...shot('05-worker-self-scope.png', '작업자 화면 — 생산성과 리더보드 모두 SELF 범위로 표시된다'),
  ]),
  ...section('SELF 배지의 뜻', [
    body(
      '"생산성 집계"와 "리더보드" 제목 옆의 배지가 지금 보고 있는 범위입니다. SELF는 본인 데이터만, ' +
      'WAREHOUSE는 창고 전체라는 뜻입니다. 작업자로 로그인하면 언제나 SELF입니다.',
    ),
    bullet('작업자 수가 1명으로 표시됩니다 — 같은 창고에 다른 사람이 일하고 있어도 그렇습니다.'),
    bullet('리더보드에는 내 행 하나만 나오고, Rank 칸은 "—"입니다.'),
    bullet('인력 수요 추정 카드는 아예 나타나지 않습니다.'),
  ]),
  ...section('내 순위는 왜 숫자로 안 보이나', [
    body(
      '순위를 보여 주려면 다른 사람들의 성적과 비교해야 합니다. "3위"라는 숫자 하나만 봐도 내 앞에 ' +
      '두 사람이 있다는 사실이 드러나고, 인원이 적은 팀에서는 그것이 곧 누구인지까지 알려 줍니다. ' +
      '그렇다고 실제 순위를 감추고 "1위"라고 적으면 거짓말입니다.',
    ),
    body(
      '그래서 이 화면은 셋 중 어느 쪽도 하지 않습니다 — 순위 칸을 비우고, 대신 본인의 처리 건수 · ' +
      '수량 · 평균 시간이라는 실제 수치를 그대로 보여 줍니다. 지난주의 나와 이번 주의 나를 비교하는 ' +
      '용도로 쓰는 것이 이 표의 취지입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 5 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 관리자가 보는 팀 생산성과 리더보드')] }),
  ...section('하는 일', [
    body(
      '창고관리자로 로그인하면 같은 화면, 같은 기간에 창고 전체가 보입니다. 배지가 WAREHOUSE로 바뀌고 ' +
      '리더보드에 순위가 매겨집니다.',
    ),
    ...shot('06-manager-leaderboard.png', '관리자 화면 — WAREHOUSE 범위, 리더보드에 순위가 표시된다'),
    body(
      '위 화면에서 관리자는 동료가 진행 중인 품질 검사 작업도 볼 수 있습니다. 다만 그 행에는 ' +
      'Complete/Cancel 버튼 대신 "본인만 종료할 수 있습니다"라고 적혀 있습니다 — 남의 작업을 대신 ' +
      '닫는 것은 시스템관리자만 할 수 있는 일이기 때문입니다.',
    ),
  ]),
  ...section('정렬 기준 세 가지', [
    infoTable([
      ['기준', '의미와 정렬 방향'],
      ['completed_count', '완료한 작업 건수. 많을수록 상위.'],
      ['total_unit_count', '처리한 수량 합계. 많을수록 상위. 작업 한 건의 크기가 제각각일 때 건수보다 공정합니다.'],
      ['avg_duration_seconds', '작업 한 건당 평균 처리 시간. 짧을수록 상위.'],
    ]),
    body(
      '기준을 바꾸면 순서가 실제로 달라집니다. 건수는 적지만 한 건에 많은 수량을 처리한 사람이 ' +
      'total_unit_count에서 앞서는 식입니다. 한 가지 기준만 보고 판단하지 마세요.',
      { italics: true },
    ),
  ]),
  ...section('리더보드를 쓸 때 주의할 점', [
    bullet('포인트·배지·레벨 같은 게임 요소는 없습니다. 순위표가 전부입니다.'),
    bullet('작업 종류가 다르면 처리 시간도 당연히 다릅니다. 적치와 품질 검사를 같은 줄에 놓고 빠르다·느리다를 말하기 어렵습니다 — 생산성 집계 표에서 작업 유형별로 나눠 보세요.'),
    bullet('자동화 에이전트가 처리한 작업은 역할이 PROCESS_AGENT로 표시됩니다. 사람과 같은 줄에 놓고 비교하지 마세요.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 6 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 인력 수요 추정')] }),
  ...section('하는 일', [
    body(
      '화면 맨 아래 "인력 수요 추정" 카드는 관리자에게만 보입니다. 네 가지를 입력하고 Forecast를 ' +
      '누르면 권장 인원이 나옵니다.',
    ),
    bullet('Role — 추정할 역할입니다 (예: INBOUND_OPERATOR).'),
    bullet('Expected Volume — 처리해야 할 예상 물량입니다. 작업 완료 시 적는 수량과 같은 단위여야 합니다.'),
    bullet('Trailing Days — 평균 처리량을 계산할 기간입니다. 기본 7일.'),
    bullet('Shift Hours — 한 사람의 하루 표준 근무시간입니다. 기본 8시간.'),
    ...shot('07-manager-forecast.png', '인력 수요 추정 결과 — 계산 근거가 함께 표시된다'),
  ]),
  ...section('이 숫자는 어떻게 나왔나', [
    body('감추는 것이 없습니다. 결과 아래 줄에 계산에 쓴 값이 전부 적혀 있고, 식은 나눗셈 두 번입니다.'),
    infoTable([
      ['단계', '계산'],
      ['1. 시간당 처리량', '트레일링 기간에 그 역할이 처리한 수량 합계 ÷ 처리 시간 합계(시간)'],
      ['2. 1인 1교대 처리량', '시간당 처리량 × Shift Hours'],
      ['3. 권장 인원', '예상 물량 ÷ 1인 1교대 처리량 (올림)'],
    ]),
    body(
      '올림이므로 2.1명은 3명이 됩니다. 근무시간을 절반으로 줄이면 필요 인원은 정확히 두 배가 ' +
      '됩니다 — 그만큼 단순한 비례식입니다.',
    ),
  ]),
  ...section('이것은 예측 모델이 아닙니다', [
    body(
      '결과 옆에 SIMPLE_RATIO라는 표시가 붙어 있고, 그 아래 문장이 같은 말을 반복합니다. 성수기·요일 ' +
      '편차·이상치 보정 같은 것은 전혀 들어 있지 않습니다. 최근 며칠 동안의 평균 속도가 앞으로도 ' +
      '유지된다고 가정한 산수일 뿐입니다.',
    ),
    body(
      '이 숫자를 인력 계획의 출발점으로 쓰는 것은 좋습니다. 근거로 인용할 때는 반드시 함께 표시되는 ' +
      '표본 건수를 같이 보세요 — 표본이 3건 미만이면 경고가 붙습니다.',
      { italics: true },
    ),
  ]),
  ...section('표본이 없으면 숫자를 만들지 않습니다', [
    body(
      '그 역할로 완료된 작업이 트레일링 기간에 하나도 없으면, 추정치 대신 오류가 나옵니다. ' +
      '0으로 나누거나 근거 없는 숫자를 조용히 내놓지 않겠다는 뜻입니다.',
    ),
    ...shot('08-forecast-no-sample.png', '해당 역할의 표본이 없어 추정을 거부한 화면'),
    body(
      '이 오류를 보면 역할 이름의 철자를 먼저 확인하고, 그래도 같다면 트레일링 기간을 늘려 보거나 ' +
      '해당 역할 작업자들에게 완료 시 수량을 기록해 달라고 요청하세요 — 수량이 하나도 없는 경우에도 ' +
      '같은 종류의 오류가 납니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- FAQ / errors ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 빨간 띠로 표시되는 오류 메시지의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['INVALID: activity_label is required when activity_type is OTHER',
      'OTHER 유형은 설명 없이 저장할 수 없습니다. Activity Label에 무슨 작업인지 한 줄 적으세요.'],
    ['FORBIDDEN: actor_id must be the calling user …',
      '로그인한 본인이 아닌 사람 명의로 기록하려 했습니다. 화면에서는 발생하지 않는 오류이며, 발생했다면 세션이 만료된 것이므로 다시 로그인하세요.'],
    ['FORBIDDEN: labor activity … belongs to another worker',
      '동료가 시작한 작업을 닫으려 했습니다. 본인이 시작한 작업만 닫을 수 있습니다(시스템관리자 제외).'],
    ['FORBIDDEN: role cannot record labor activities',
      '현재 역할에는 작업 기록 권한이 없습니다. 오른쪽 위 역할 배지를 확인하세요.'],
    ['FORBIDDEN: role cannot forecast labor demand',
      '인력 수요 추정은 창고관리자·시스템관리자만 조회할 수 있습니다.'],
    ['INVALID: labor activity … is not IN_PROGRESS',
      '이미 완료했거나 취소한 작업입니다. Refresh를 눌러 최신 목록을 확인하세요.'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 사람이 먼저 이 기록을 바꿨습니다. Refresh 후 다시 시도하세요.'],
    ['INVALID: no completed … activities in the trailing … days',
      '그 역할로 완료된 작업이 기간 안에 없어 추정할 수 없습니다. 역할 철자와 기간을 확인하세요.'],
    ['INVALID: trailing … activities for … recorded no unit_count',
      '완료된 작업은 있지만 처리 수량이 하나도 기록되지 않아 처리 속도를 알 수 없습니다. 완료 시 수량을 적도록 안내하세요.'],
    ['INVALID: expected_volume must be positive',
      '예상 물량에 0이나 음수를 넣었습니다.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/labor-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: '인력 관리 · 운영자 매뉴얼', size: 18, color: '94A3B8' })],
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
