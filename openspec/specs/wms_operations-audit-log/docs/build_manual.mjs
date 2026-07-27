// Builds the 감사 로그 조회 감사자 매뉴얼 (.docx) from the screenshots captured by
// frontend/playwright/e2e/audit-log-flow.spec.ts.
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
const OUT = path.resolve(HERE, 'operations-audit-log-auditor-manual.docx')

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
    children: [new TextRun({ text: '감사 로그 조회', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '감사자 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '감사담당자(AUDITOR) · 시스템관리자(WMS_ADMIN)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '창고 운영 이력을 사후에 확인해야 하는 감사·재무 담당자와 시스템관리자'],
    ['다루는 화면', 'Audit Log (/operations/audit-log)'],
    ['필요 권한', 'AUDITOR 또는 WMS_ADMIN. 다른 역할에게는 메뉴 자체가 보이지 않습니다'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (audit-log-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 화면은 창고에서 일어난 모든 변경 이력을 한국어 문장으로 읽는 자리입니다. 누가 언제 무엇을 ' +
    '했는지를 기간·담당자·업무 종류로 걸러서 보고, 필요하면 그 결과를 CSV 파일로 내려받을 수 ' +
    '있습니다. 발주 승인, 입고 검수, 도크 배정, 설비 명령, 인력 작업, AI 에이전트의 자율 조치까지 ' +
    '— 시스템에 기록을 남기는 모든 작업이 여기에 모입니다.',
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('이 기록은 새로 만든 것이 아닙니다')] }),
  body(
    '먼저 알아 두면 좋은 점이 있습니다. 이 화면이 보여 주는 기록은 이 화면을 위해 따로 수집한 것이 ' +
    '아닙니다. WMS는 처음부터 모든 변경 작업을 자동으로 기록해 왔고, 그 기록은 사람이 지우거나 ' +
    '고칠 수 없습니다. 이 화면이 새로 하는 일은 두 가지뿐입니다.',
  ),
  bullet('기계가 읽기 좋은 형태로 쌓여 있던 기록을 사람이 읽는 한 문장으로 바꿔 보여 줍니다.'),
  bullet('그 기록을 기간·담당자·업무 종류로 걸러 찾고, 내려받을 수 있게 합니다.'),
  body(
    '그래서 이 화면에는 기록을 수정하거나 삭제하는 기능이 없습니다. 앞으로도 생기지 않습니다.',
    { italics: true },
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('요약 문장은 AI가 쓴 것이 아닙니다')] }),
  body(
    '"요약 (자동 생성)" 열에 보이는 한국어 문장은 AI가 매번 새로 지어내는 것이 아니라, 정해진 ' +
    '규칙으로 조립된 문장입니다. 같은 사건은 언제 몇 번을 읽어도 글자 하나까지 똑같은 문장으로 ' +
    '나옵니다. 감사 자료로 인용해도 나중에 문장이 달라져 있을 걱정이 없다는 뜻입니다.',
  ),
  body(
    '기록의 원본 값이 궁금하면 각 행 아래 "원본 변경 전/후 (JSONB)"를 펼치면 됩니다. 요약은 ' +
    '원본을 읽기 쉽게 옮긴 것일 뿐, 원본을 대체하지 않습니다.',
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('누가 볼 수 있습니까')] }),
  infoTable([
    ['역할', '이 화면'],
    ['AUDITOR (감사담당)', '전체 조회와 내보내기가 가능합니다. 이 역할은 시스템 어디에서도 데이터를 바꿀 수 없습니다 — 기록을 고칠 수 있는 사람은 감사자가 될 수 없기 때문입니다.'],
    ['WMS_ADMIN (시스템관리)', '전체 조회와 내보내기가 가능합니다.'],
    ['그 밖의 모든 역할', '왼쪽 메뉴에 Audit Log 항목이 나타나지 않고, 주소를 직접 입력해도 열리지 않습니다.'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 1 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 감사 로그 열기')] }),
  ...section('하는 일', [
    body(
      '왼쪽 메뉴 맨 아래 OVERSIGHT 그룹에서 Audit Log를 선택합니다. 별도 조작 없이 최근 기록이 ' +
      '최신순으로 표시됩니다.',
    ),
    ...shot('02-audit-log-in-korean.png', '감사 로그 첫 화면 — 최근 작업이 한국어 한 문장씩으로 정리된다'),
    body('표의 다섯 개 열이 각각 무엇인지부터 익혀 두면 이후가 쉽습니다.'),
    infoTable([
      ['열', '내용'],
      ['시각', '그 작업이 기록된 시각입니다. 항상 최신이 위에 옵니다.'],
      ['행위자', '작업을 수행한 사람의 계정입니다. AI 에이전트가 한 일이면 에이전트 계정이 표시됩니다.'],
      ['명령', '어떤 기능이 실행되었는지를 나타내는 시스템 이름입니다. 아래 "명령" 필터의 선택지와 같은 값입니다.'],
      ['엔티티', '무엇에 대한 작업이었는지 — 발주, 입고 건, 도크, 설비 등 — 와 그 대상의 식별자 앞 8자리입니다.'],
      ['요약 (자동 생성)', '위 네 가지와 변경 내용을 합쳐 만든 한국어 설명입니다.'],
    ]),
  ]),
  ...section('요약 문장 읽는 법', [
    body('문장은 대체로 "무엇이 어떻게 되었다 — 핵심 값들." 형태입니다. 몇 가지 예를 보겠습니다.'),
    infoTable([
      ['요약 문장', '읽는 법'],
      ['도크 AUDIT-E2E-DOCK-01(AUDIT-E2E 감사용 하역장)가 등록되었다 — 상태 AVAILABLE.', '새로 만들어진 항목입니다. 만들어진 직후의 상태가 뒤에 붙습니다.'],
      ['도크 AUDIT-E2E-DOCK-01의 상태가 변경되었다 — AVAILABLE → CLOSED.', '화살표는 상태가 바뀐 것입니다. 왼쪽이 이전, 오른쪽이 이후입니다.'],
      ['입고 수량이 확정되었다 — 수령 40 / 예정 40, 상태 ARRIVED → QC_PENDING.', '숫자와 상태 전이가 함께 나옵니다. 수령과 예정이 다르면 그 차이가 그대로 보입니다.'],
      ['업무 오더가 취소되었다 — 상태 QUEUED → CANCELLED, 사유 상위 웨이브 취소.', '작업자가 사유를 남긴 경우에만 "사유"가 붙습니다. 없으면 아예 표시되지 않습니다.'],
    ]),
    body(
      '값이 기록되지 않은 자리에는 긴 줄표(—)가 들어갑니다. 오류가 아니라 "그 항목은 이 작업에서 ' +
      '기록되지 않았다"는 뜻입니다.',
    ),
    callout(
      '처음 보는 문장 형태가 나온다면',
      '"○○ 엔티티에 대해 wms_xxx 명령이 실행되었다."처럼 밋밋한 문장이 보이면, 시스템에 새로 ' +
      '추가된 기능이라 아직 전용 설명 문구가 준비되지 않은 것입니다. 기록 자체는 정상이며, 각 행의 ' +
      '"원본 변경 전/후"를 펼치면 무슨 일이 있었는지 확인할 수 있습니다. 자주 보인다면 관리자에게 ' +
      '알려 주세요.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 2 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. 찾는 기록만 걸러 보기')] }),
  ...section('하는 일', [
    body(
      '화면 위쪽 필터 상자에서 조건을 고르고 Search를 누릅니다. 여러 조건을 동시에 걸면 모두 ' +
      '만족하는 기록만 남습니다. Reset을 누르면 조건이 전부 지워집니다.',
    ),
    ...shot('03-filtered-by-command.png', '명령을 하나 고르고 Search — 그 작업만 남는다'),
    infoTable([
      ['필터', '쓰임새'],
      ['시작일 / 종료일', '기간을 한정합니다. 양쪽 날짜 모두 포함됩니다 — 종료일을 오늘로 두면 오늘 하루치가 전부 들어옵니다.'],
      ['행위자', '특정 담당자가 한 일만 봅니다. 목록에는 실제로 기록을 남긴 적이 있는 계정만 나옵니다.'],
      ['엔티티 종류', '발주·입고·도크·설비처럼 대상의 종류로 좁힙니다.'],
      ['명령', '어떤 기능이 실행되었는지로 좁힙니다. "발주 확정만 모아 보기" 같은 조회에 씁니다.'],
      ['상관관계 ID', '하나의 업무 흐름에 붙는 추적 번호입니다. 이것으로 걸면 그 흐름이 남긴 기록이 한 화면에 모입니다.'],
    ]),
    body(
      '행위자·엔티티 종류·명령 세 목록은 이 창고에 **실제로 기록이 있는 값만** 보여 줍니다. 목록에 ' +
      '없는 값은 애초에 일어난 적이 없는 일이므로, 고를 수 없는 것이 정상입니다.',
    ),
  ]),
  ...section('결과 요약 줄 읽기', [
    body('표 바로 위 한 줄에 이번 조회의 규모가 요약됩니다.'),
    bullet('전체 — 조건에 맞는 기록의 총 건수입니다. 페이지를 넘겨도 이 숫자는 변하지 않습니다.'),
    bullet('페이지 n / m — 지금 몇 번째 장을 보고 있는지입니다. 한 장에 20건씩 표시됩니다.'),
    bullet('이 페이지 — 지금 화면에 실제로 보이는 건수입니다. 마지막 장에서는 20건보다 적습니다.'),
    bullet('판단 근거가 붙은 행 — 이 페이지에서 AI 에이전트가 이유를 남긴 기록이 몇 건인지입니다(4장 참고).'),
    ...shot('05-pagination-last-page.png', '마지막 장 — 전체 건수는 그대로이고 "다음" 버튼이 비활성화된다'),
    body(
      '아래쪽 "← 이전" / "다음 →" 버튼으로 장을 넘깁니다. 마지막 장에 도달하면 "다음"이 비활성화 ' +
      '됩니다. 조건을 새로 걸고 Search를 누르면 항상 첫 장부터 다시 시작합니다.',
    ),
  ]),
  ...section('조건에 맞는 기록이 없을 때', [
    body(
      '"해당 조건에 맞는 감사 이벤트가 없습니다."가 표시되고 전체 건수가 0이 됩니다. 이전 결과가 ' +
      '남아 있지 않으므로, 화면에 보이는 것은 언제나 방금 건 조건의 결과입니다. 기간을 너무 좁게 ' +
      '잡았거나 상관관계 ID를 잘못 입력한 경우가 대부분입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 3 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. AI 에이전트가 한 일과 그 이유 확인하기')] }),
  ...section('하는 일', [
    body(
      '이 시스템에서는 일부 작업을 AI 에이전트가 사람 대신 수행합니다. 그런 기록에는 노란 테두리 ' +
      '상자로 "에이전트 판단 근거"가 함께 표시됩니다. 에이전트가 그 작업을 하면서 스스로 남긴 ' +
      '설명입니다.',
    ),
    ...shot('04-agent-reasoning-joined.png', '에이전트가 한 구매 요청과, 그 옆에 붙은 판단 근거'),
    body('이 상자가 감사 관점에서 중요한 이유는 두 가지입니다.'),
    bullet('무엇을 했는지(요약 문장)와 왜 했는지(판단 근거)가 한 줄에 함께 있습니다. 두 기록을 따로 찾아 맞춰 볼 필요가 없습니다.'),
    bullet('근거는 작업 시점에 에이전트가 남긴 것이고, 나중에 바꿀 수 없습니다. 사후에 만들어 붙인 설명이 아닙니다.'),
    body(
      '요약 문장 끝에도 같은 내용이 "(사유: …)" 형태로 붙습니다. CSV로 내려받았을 때도 이 사유가 ' +
      '문장 안에 그대로 들어가므로, 표 하나만 보고도 근거를 읽을 수 있습니다.',
    ),
  ]),
  ...section('상관관계 ID로 흐름 전체 보기', [
    body(
      '노란 상자 아래에 correlation_id 값이 적혀 있습니다. 그 값을 복사해 "상관관계 ID" 필터에 ' +
      '넣고 Search를 누르면, 그 하나의 판단에서 비롯된 기록이 전부 모입니다 — 에이전트가 근거를 ' +
      '기록한 행과, 실제로 실행한 작업의 행이 나란히 나옵니다.',
    ),
    callout(
      '판단 근거가 없는 기록이 대부분입니다',
      '사람이 직접 한 작업에는 노란 상자가 붙지 않습니다. 정상입니다. 판단 근거는 AI 에이전트가 ' +
      '자율적으로 수행한 작업에만 남고, 그 외의 기록은 근거 없이 요약만 표시됩니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 4 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. CSV로 내려받기')] }),
  ...section('하는 일', [
    body(
      '필터를 원하는 대로 맞춘 뒤 Export CSV를 누릅니다. 화면에 보이는 20건이 아니라 **조건에 맞는 ' +
      '전체 기록**이 파일로 저장됩니다. 파일 이름은 wms-audit-log-(내려받은 시각).csv 형태입니다.',
    ),
    body('파일에 들어가는 열은 여덟 개입니다.'),
    bullet('created_at (시각), actor_email (행위자), command (명령), entity_type (엔티티 종류), entity_id (대상 식별자)'),
    bullet('correlation_id (상관관계 ID), summary_ko (한국어 요약), agent_reasoning (에이전트 판단 근거)'),
    body(
      '엑셀에서 바로 열어도 한글이 깨지지 않도록 만들어져 있습니다. 그래도 깨져 보인다면 엑셀의 ' +
      '"데이터 → 텍스트/CSV 가져오기"에서 UTF-8을 지정해 여세요.',
    ),
  ]),
  ...section('한 번에 받을 수 있는 양에는 한도가 있습니다', [
    body(
      '조건에 맞는 기록이 10,000건을 넘으면 파일이 만들어지지 않고 빨간 오류 띠가 표시됩니다. ' +
      '기간을 좁히거나 조건을 더 걸어서 다시 시도하세요.',
    ),
    callout(
      '한도를 넘으면 잘라서 주지 않고 거절합니다',
      '앞의 10,000건만 잘라서 내려받게 하면, 받은 사람은 그것이 전체라고 믿게 됩니다. 일부만 담긴 ' +
      '파일을 전체로 오해한 채 감사 자료로 쓰는 것이 훨씬 위험하기 때문에, 이 시스템은 잘라 주는 ' +
      '대신 거절하고 조건을 좁히라고 안내합니다.',
    ),
  ]),
  ...section('내려받은 사실도 기록에 남습니다', [
    body(
      '내보내기가 끝나면 초록색 알림이 뜨고, 목록이 새로 고쳐지면서 맨 위에 방금 한 내보내기가 ' +
      '기록으로 나타납니다. "감사 로그 30건이 내보내졌다 — 기간 (처음) ~ (현재)."처럼 표시됩니다.',
    ),
    ...shot('06-the-export-audits-itself.png', '방금 한 내보내기가 그 자체로 감사 기록이 되어 있다'),
    body(
      '누가 언제 어떤 조건으로 감사 로그를 통째로 내려받았는지도 감사 대상이라는 뜻입니다. ' +
      '"지난달 전체 기록을 누가 받아 갔는가"를 나중에 확인할 수 있습니다. 명령 필터에서 ' +
      'wms_export_audit_log를 고르면 내보내기 이력만 모아 볼 수 있습니다.',
    ),
    body(
      '자기가 방금 받은 파일 안에는 그 내보내기 기록이 들어 있지 않습니다. 파일 내용을 확정한 ' +
      '다음에 기록을 남기기 때문이며, 다음 번 조회부터 보입니다.',
      { italics: true },
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 5 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 권한과 접근 제한')] }),
  ...section('메뉴가 보이지 않는 경우', [
    body(
      'AUDITOR나 WMS_ADMIN이 아닌 역할로 로그인하면 왼쪽 메뉴에 Audit Log 항목이 아예 나타나지 ' +
      '않습니다. 오른쪽 위 역할 배지에서 현재 역할을 확인할 수 있습니다.',
    ),
    ...shot('07-buyer-has-no-audit-nav.png', '구매 담당자로 로그인한 화면 — OVERSIGHT 그룹 자체가 없다'),
    body(
      '주소창에 /operations/audit-log를 직접 입력해도 Overview 화면으로 되돌아옵니다. 화면을 ' +
      '가려 두는 것만으로 끝나지 않고, 조회 기능 자체가 서버에서 거절하도록 되어 있습니다 — ' +
      '권한이 없는 계정으로는 어떤 방법으로도 이 기록을 요약된 형태로 받아 갈 수 없습니다.',
    ),
  ]),
  ...section('다른 회사(테넌트)의 기록', [
    body(
      '한 계정은 자기가 속한 조직의 기록만 볼 수 있습니다. 여러 조직에 속해 있다면 화면 오른쪽 ' +
      '위에서 조직을 전환한 뒤 다시 조회하세요. 소속되지 않은 조직의 기록은 조회 자체가 ' +
      '거절됩니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- messages ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 빨간 띠로 표시되는 오류 메시지의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['FORBIDDEN: role cannot read the operations audit log (WMS_ADMIN or AUDITOR required)',
      '현재 역할에는 감사 로그 열람 권한이 없습니다. 오른쪽 위 역할 배지를 확인하세요. 소속되지 않은 조직을 조회했을 때도 같은 메시지가 나옵니다.'],
    ['INVALID: export matches … events, over the … row safety limit',
      '내보내려는 기록이 한도(10,000건)를 넘었습니다. 기간을 좁히거나 조건을 더 걸어 다시 시도하세요.'],
    ['INVALID: date_from must not be after date_to',
      '시작일이 종료일보다 뒤입니다. 두 날짜를 바꿔 입력하세요.'],
    ['INVALID: tenant_id is required',
      '조직이 선택되지 않은 상태입니다. 다시 로그인하거나 오른쪽 위에서 조직을 고르세요.'],
    ['INVALID: limit must be between 1 and 500 / offset must be >= 0',
      '화면에서 정상적으로 조작했다면 나오지 않는 메시지입니다. 나온다면 관리자에게 알려 주세요.'],
  ]),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/audit-log-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: '감사 로그 조회 · 감사자 매뉴얼', size: 18, color: '94A3B8' })],
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
