// Builds the 슬롯팅 최적화 운영자 매뉴얼 (.docx) from the screenshots captured by
// frontend/playwright/e2e/slotting-flow.spec.ts.
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
const OUT = path.resolve(HERE, 'slotting-optimization-operator-manual.docx')

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

function infoTable(rows, col0 = 2600) {
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

/** Three-column variant for the ABC worked example. */
function triTable(rows) {
  const cols = [3120, 3120, 3120]
  return new Table({
    width: { size: CONTENT_DXA, type: WidthType.DXA },
    columnWidths: cols,
    rows: rows.map((cells, i) =>
      new TableRow({
        children: cells.map((c, j) =>
          new TableCell({
            borders,
            width: { size: cols[j], type: WidthType.DXA },
            shading: { fill: i === 0 ? 'D5E8F0' : j === 0 ? 'F1F5F9' : 'FFFFFF', type: ShadingType.CLEAR },
            margins: { top: 80, bottom: 80, left: 120, right: 120 },
            children: [new Paragraph({ children: [new TextRun({ text: c, bold: i === 0 || j === 0 })] })],
          }),
        ),
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
    children: [new TextRun({ text: '슬롯팅 최적화', bold: true, size: 56 })] }),
  new Paragraph({ spacing: { after: 400 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '운영자 매뉴얼', size: 40, color: '2563EB' })] }),
  new Paragraph({ spacing: { after: 100 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: '창고관리자(WAREHOUSE_MANAGER) · 입고담당자(INBOUND_OPERATOR)용', size: 24, color: '64748B' })] }),
  new Paragraph({ spacing: { after: 900 }, alignment: AlignmentType.CENTER,
    children: [new TextRun({ text: 'WMS · ProcessGPT Sample App', size: 22, color: '64748B' })] }),
  infoTable([
    ['항목', '내용'],
    ['대상 독자', '보관 위치와 SKU 배치를 관리하는 창고관리자, 실제로 물건을 옮기는 입고담당자'],
    ['다루는 화면', 'Slotting (/slotting)'],
    ['필요 권한',
      '위치 등록·활성화, 등급 정책 관리, 추천 승인·반려: WAREHOUSE_MANAGER, WMS_ADMIN / ' +
      'SKU 배정 선언·재배정, 승인된 추천 적용: 위 두 역할 + INBOUND_OPERATOR / ' +
      '속도 계산·추천 생성: 위 역할들 + PROCESS_AGENT(자동화 에이전트)'],
    ['화면 캡처 출처', '실제 Playwright 자동화 실행 (slotting-flow.spec.ts)'],
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- TOC ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('목차')] }),
  new TableOfContents('목차', { hyperlink: true, headingStyleRange: '1-2' }),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- intro ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('시작하기 전에')] }),
  body(
    '이 매뉴얼은 자주 나가는 물건을 손이 잘 닿는 자리로, 드물게 나가는 물건을 안쪽 자리로 ' +
    '옮기도록 시스템이 도와주는 과정을 순서대로 설명합니다. 위치를 등록하는 일부터 시작해 ' +
    '추천을 받고, 그 추천을 사람이 승인하고, 실제로 반영하기까지가 한 화면 안에 있습니다.',
  ),
  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('왜 자리를 바꾸나')] }),
  body(
    '피킹 작업 시간의 대부분은 물건을 집는 시간이 아니라 걷는 시간입니다. 하루에 백 번 나가는 ' +
    '물건이 창고 안쪽 끝에 있고, 한 달에 한 번 나가는 물건이 포장대 바로 옆에 있으면, 그 차이가 ' +
    '매일 쌓입니다. 슬롯팅은 그 어긋남을 찾아서 알려 주는 기능입니다.',
  ),
  body(
    '핵심은 두 가지 숫자를 나란히 놓는 것입니다 — 이 SKU가 얼마나 자주 나가는가(등급), ' +
    '그리고 지금 있는 자리가 얼마나 접근하기 좋은가(순위). 둘이 어긋나면 추천이 나옵니다.',
    { italics: true },
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('접근성 순위는 여러분이 정하는 숫자입니다') ] }),
  body(
    '위치마다 "접근성 순위"라는 정수를 하나 붙입니다. 낮을수록 좋은 자리입니다 — 1번은 포장대 ' +
    '바로 옆, 40번은 창고 안쪽 구석 같은 식입니다.',
  ),
  body(
    '이 숫자는 시스템이 계산하지 않습니다. 창고 도면을 읽거나 실제 동선을 재는 기능이 없기 ' +
    '때문에, 현장을 아는 사람이 직접 매겨야 합니다. 순위를 잘못 매기면 추천도 그대로 틀립니다 — ' +
    '시스템은 그 사실을 알아차릴 방법이 없습니다.',
    { italics: true },
  ),
  body(
    '숫자의 절대값에는 의미가 없고, 같은 창고 안에서의 상대 비교만 의미가 있습니다. 1, 2, 3처럼 ' +
    '붙여도 되고 10, 20, 30처럼 띄워 붙여도 됩니다(나중에 사이에 끼워 넣기 좋습니다).',
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('A·B·C 등급이 무슨 뜻인가')] }),
  body(
    '관찰 기간 동안 나간 수량을 많은 순으로 줄 세운 다음, 위에서부터 누적해서 전체의 80%를 채울 ' +
    '때까지가 A등급, 95%까지가 B등급, 나머지가 C등급입니다. 재고 관리에서 오래 쓰는 방식(ABC 분석)을 ' +
    '그대로 따른 것입니다.',
  ),
  body('예를 들어 관찰 기간에 네 품목이 모두 합쳐 100개 나갔다면:'),
  triTable([
    ['SKU', '나간 수량 (누적 비중)', '등급'],
    ['P1', '60개 (60%)', 'A'],
    ['P4', '20개 (누적 80%)', 'A'],
    ['P2', '15개 (누적 95%)', 'B'],
    ['P3', '5개 (누적 100%)', 'C'],
  ]),
  new Paragraph({ spacing: { before: 140 }, children: [] }),
  body(
    '경계에 정확히 걸리는 품목은 위쪽 등급에 들어갑니다(누적 80.0%면 A, 95.0%면 B). ' +
    '요령은 간단합니다 — A등급은 "이 창고 물동량의 대부분을 만드는 소수의 품목"이고, ' +
    '이들을 좋은 자리에 두는 것이 슬롯팅의 거의 전부입니다.',
  ),

  new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun('가장 중요한 원칙: 모르면 모른다고 합니다')] }),
  body(
    '관찰 기간에 한 번도 나가지 않은 SKU는 "C등급(느린 품목)"으로 분류되지 않습니다. ' +
    '아예 등급을 매기지 않고 계산에서 빼며, 몇 개를 뺐는지만 화면에 표시합니다.',
  ),
  body(
    '이 구분은 중요합니다. "다섯 번 나갔다"와 "한 번도 안 나갔다"는 전혀 다른 정보인데, ' +
    '둘 다 C등급으로 뭉뚱그리면 "이 품목은 안 팔리니 안쪽으로 넣자"는 잘못된 결정을 부릅니다 — ' +
    '실제로는 신규 품목이라 아직 이력이 없는 것일 수도 있으니까요.',
    { italics: true },
  ),
  body(
    '화면에서는 "분류됨"과 "신호 없어 제외" 두 숫자가 나란히 표시되고, 둘을 더하면 항상 ' +
    '"대상 SKU"가 됩니다. 이 세 숫자를 함께 보는 습관을 들이세요.',
  ),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 1 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('1. 보관 위치 등록하기')] }),
  ...section('하는 일', [
    body('왼쪽 메뉴 WMS 그룹에서 Slotting을 선택하면 이 화면이 열립니다.'),
    body(
      '처음에는 등록된 위치가 하나도 없습니다. 슬롯팅은 "이 자리가 저 자리보다 낫다"는 비교가 ' +
      '있어야 성립하므로, 여기서부터 시작합니다.',
    ),
    ...shot('01-empty-board.png', '처음 연 Slotting 화면 — 아직 아무것도 등록되어 있지 않다'),
    body('상단 "보관 위치 레지스트리" 카드에서 네 가지를 입력합니다.'),
    bullet('Zone Code — 구역 라벨입니다(예: PACK_ADJACENT, BULK_STORAGE). 자유 텍스트이며 계층 구조가 아닙니다.'),
    bullet('Location Code — 창고 안에서 겹치지 않는 위치 코드입니다(예: A-01-01). 같은 코드를 다시 등록하면 거부됩니다.'),
    bullet('Accessibility Rank — 접근성 순위입니다. 1 이상의 정수이고 낮을수록 좋은 자리입니다.'),
    bullet('Capacity — 참고용 수용량입니다. 적어 두어도 되지만 어떤 검증에도 쓰이지 않습니다(용량 초과를 막아 주지 않습니다).'),
    ...shot('02-locations-registered.png', '접근성 순위를 달리한 위치 네 곳을 등록한 상태'),
  ]),
  ...section('확인할 점', [
    bullet('등록 직후 상태는 ACTIVE입니다. Deactivate를 누르면 INACTIVE가 되고, 그 자리는 앞으로 새 배정이나 추천의 대상이 되지 않습니다.'),
    bullet('비활성화해도 이미 그 자리에 배정된 SKU가 쫓겨나지는 않습니다 — 배정 기록은 "지금 실물이 저기 있다"는 진술이고, 자리를 잠근다고 실물이 움직이지는 않기 때문입니다. 남아 있는 SKU가 있으면 화면이 그 건수를 알려 줍니다.'),
    bullet('좋은 자리(낮은 순위)를 처음부터 넉넉히 등록해 두세요. 추천은 "비어 있고, 다른 추천이 노리지 않고, 순위가 가장 좋은 자리"를 우선 고르므로, 좋은 자리가 전부 차 있으면 옮길 곳이 없습니다.'),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 2 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('2. SKU가 지금 어디 있는지 선언하기')] }),
  ...section('하는 일', [
    body(
      '"SKU 위치 배정" 카드에서 품목과 위치를 고르고 Declare Assignment를 누릅니다. 한 창고 ' +
      '안에서 한 품목은 배정을 하나만 가집니다.',
    ),
    body(
      '자리를 바꾸려면 표 오른쪽의 "이동…" 드롭다운에서 새 위치를 고르면 됩니다. 같은 품목에 ' +
      '배정을 두 번 선언하려 하면 거부되고, 대신 이 재배정 경로를 쓰라는 안내가 나옵니다.',
    ),
  ]),
  ...section('이 값은 시스템이 알아낸 것이 아닙니다', [
    body(
      '재고 원장에는 "어느 위치인가"라는 항목이 아예 없습니다. 입고·검수·적치 화면 어디에서도 ' +
      '위치를 입력하지 않기 때문에, 시스템은 물건이 어느 선반에 올라갔는지 알 방법이 없습니다.',
    ),
    body(
      '그래서 이 표는 사람이 적어 넣는 선언입니다. 적어 넣은 내용과 실제 창고가 어긋나도 시스템은 ' +
      '알아차리지 못합니다 — 선언만 하고 물건을 옮기지 않았거나, 옮기고 나서 선언을 고치지 않으면 ' +
      '그대로 어긋난 채 남습니다. 재고 실사에서 발견될 문제입니다.',
      { italics: true },
    ),
    body(
      '실무 요령: 적치를 마친 사람이 그 자리에서 바로 선언하는 것이 가장 정확합니다. ' +
      '입고담당자에게도 이 권한이 열려 있는 이유가 그것입니다.',
    ),
  ]),
  ...section('아직 선언하지 않은 품목은 어떻게 되나', [
    body(
      '괜찮습니다. 선언이 없는 품목도 등급만 나오면 추천 대상이 됩니다 — "현재 위치"가 빈칸(—)이고 ' +
      '사유가 UNASSIGNED_HIGH_VELOCITY인 추천이 나옵니다.',
    ),
    body(
      '이런 품목을 추천에서 빼면, 아무도 관리하지 않은 품목이 영영 관리되지 않습니다. ' +
      '그래서 일부러 포함시킵니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 3 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('3. 등급별 목표 자리 정하기')] }),
  ...section('하는 일', [
    body(
      '"A등급 물건은 순위 몇 번 이하에 있어야 하는가"를 등급마다 정합니다. 예를 들어 A등급 상한을 ' +
      '5로 잡으면, A등급 SKU가 순위 6 이상 자리에 있을 때 재배치가 추천됩니다.',
    ),
    ...shot('03-assignments-and-policies.png', 'SKU 배정 두 건과 A·C 등급 정책을 등록한 상태 (B등급은 일부러 비워 두었다)'),
    body(
      '정책을 등록하면 "상한을 만족하는 ACTIVE 위치"가 몇 곳인지 함께 표시됩니다. 이 숫자가 0이면 ' +
      '그 등급에 대한 추천은 절대 나오지 않으니, 좋은 자리를 더 등록하거나 상한을 완화하세요.',
    ),
  ]),
  ...section('시스템 기본값이 없는 이유', [
    body(
      '정책을 등록하지 않은 등급은 추천 계산에서 그냥 빠집니다. 임의의 기본값을 적용하지 않습니다.',
    ),
    body(
      '위치가 다섯 곳뿐인 창고와 오백 곳인 창고에서 "순위 5 이하"는 전혀 다른 뜻이기 때문입니다. ' +
      '작은 창고에 그 기본값을 적용하면 모든 자리가 A등급 자격을 얻어 추천이 통째로 무의미해집니다. ' +
      '그런 거짓 추천을 만드느니 "이 창고는 아직 B등급 정책을 정하지 않았다"고 그대로 알리는 쪽을 ' +
      '택했습니다.',
      { italics: true },
    ),
    body(
      '추천을 생성하면 정책이 없어 빠진 등급이 화면에 이름으로 표시됩니다. 그 등급의 추천을 받고 ' +
      '싶다면 정책을 등록한 뒤 다시 생성하면 됩니다.',
    ),
  ]),
  ...section('상한을 바꾸면 기존 추천은 어떻게 되나', [
    body(
      '이미 만들어진 추천은 옛 상한으로 만들어진 그대로 남습니다. 새 상한을 반영하려면 추천을 ' +
      '다시 생성해야 하고, 화면도 그렇게 안내합니다.',
    ),
    body(
      '속도 계산 결과(스냅샷)는 그대로 남아 있으므로, 재생성할 때 원장을 다시 훑지 않습니다. ' +
      '상한을 몇 번 바꿔 가며 결과를 비교해 보는 것이 정상적인 사용법입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 4 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('4. 출하 속도 계산하기')] }),
  ...section('하는 일', [
    body(
      '관찰 시작일과 종료일을 정하고 Compute Velocity를 누릅니다. 그 기간에 재고에서 빠져나간 ' +
      '수량을 품목별로 합산해 A·B·C 등급을 매깁니다.',
    ),
    body(
      '기간은 길수록 안정적이지만 최근 변화를 늦게 반영합니다. 계절성이 있는 품목이 많다면 ' +
      '지난 4주 정도가 무난한 출발점입니다.',
    ),
  ]),
  ...section('결과가 비어 있어도 고장이 아닙니다', [
    body(
      '아래는 관찰 기간에 소비 이력이 하나도 없을 때의 화면입니다. 대상 SKU 일곱 개 전부가 ' +
      '"신호 없어 제외"로 잡혔고, 분류된 품목은 0개입니다.',
    ),
    ...shot('04-velocity-no-signal.png', '소비 이력이 없어 아무 등급도 매기지 않은 화면 — 노란 안내가 그 사실을 밝힌다'),
    body(
      '현재 이 시스템에는 출고로 재고를 차감하는 기능이 아직 들어 있지 않습니다. 입고·검수·적치는 ' +
      '동작하지만 "물건이 나갔다"를 기록하는 화면이 없어서, 실데이터로 계산하면 대개 이 화면이 ' +
      '나옵니다.',
    ),
    body(
      '이때 시스템이 하지 않는 일이 중요합니다 — 신호가 없는 품목을 전부 "C등급(느린 품목)"으로 ' +
      '찍어 두지 않습니다. 만약 그렇게 했다면 "이 물건들은 안 나가니 안쪽으로 넣자"는 추천이 ' +
      '줄줄이 나왔을 것이고, 그건 근거 없는 조언입니다. 분류할 근거가 없으면 분류하지 않고, ' +
      '몇 개를 그렇게 뺐는지만 알려 줍니다.',
      { italics: true },
    ),
    body(
      '나중에 출고 처리 기능이 추가되면, 이 화면은 아무것도 고치지 않아도 그때부터 실제 숫자를 ' +
      '보여 주기 시작합니다.',
    ),
  ]),
  ...section('신호가 있을 때의 화면', [
    body(
      '소비 이력이 쌓이면 상태가 COMPUTED로 바뀌고 품목별 등급이 표로 나옵니다. 아래는 네 품목이 ' +
      '각각 60·20·15·5개 나간 경우입니다 — 누적 비중이 60%, 80%, 95%, 100%가 되어 A, A, B, C로 ' +
      '나뉘었습니다.',
    ),
    ...shot('05-velocity-abc.png', '소비 이력이 있는 네 품목이 A·A·B·C로 분류된 화면'),
    body(
      '여기서도 "신호 없어 제외 3"이 함께 표시됩니다. 이력이 있는 품목만 등급을 받았고, 나머지 ' +
      '세 품목은 여전히 판단하지 않았다는 뜻입니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 5 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('5. 재배치 추천 받기')] }),
  ...section('하는 일', [
    body(
      '속도 계산이 끝나면 Generate Recommendations 버튼이 활성화됩니다. 누르면 방금 나온 등급과 ' +
      '등급별 정책, 그리고 현재 배정을 대조해 추천을 만듭니다.',
    ),
    ...shot('06-recommendations-generated.png', '추천 2건이 생성된 화면 — 만들지 않은 이유도 함께 표시된다'),
    body('추천에는 두 가지 사유가 있습니다.'),
    bullet('RELOCATE_UNDERSERVED — 지금 있는 자리의 순위가 등급 상한을 넘었습니다. 위 화면에서는 A등급 P1이 순위 20 자리에 있어 순위 1 자리로 옮기라는 추천이 나왔습니다.'),
    bullet('UNASSIGNED_HIGH_VELOCITY — 등급은 나왔는데 어디 있는지 선언된 적이 없습니다. "현재 위치"가 빈칸으로 표시됩니다.'),
  ]),
  ...section('만들지 않은 이유도 전부 알려 줍니다', [
    body('추천이 나오지 않은 품목이 조용히 사라지지 않도록, 네 가지 숫자가 함께 표시됩니다.'),
    infoTable([
      ['표시', '뜻'],
      ['정책 없어 제외된 등급', '그 등급의 목표 상한을 이 창고가 정한 적이 없습니다. 정책을 등록한 뒤 다시 생성하세요.'],
      ['이미 적정 위치', '이미 상한 안에 있어서 옮길 이유가 없습니다. 움직이는 것 자체가 비용이므로 추천하지 않습니다.'],
      ['검토 대기 중이라 제외', '같은 품목에 아직 승인/반려되지 않은 추천이 이미 있습니다. 여러 번 생성해도 중복이 쌓이지 않습니다.'],
      ['대상 위치 없음', '상한을 만족하는 빈 ACTIVE 자리가 없습니다. 좋은 자리를 더 등록하거나 상한을 완화하세요.'],
    ], 3200),
    new Paragraph({ spacing: { before: 140 }, children: [] }),
    body(
      '추천 위치를 고르는 순서도 정해져 있습니다 — 아무도 배정되지 않은 자리를 먼저, 그 다음 다른 ' +
      '추천이 아직 노리지 않는 자리를, 그 다음 순위가 가장 좋은 자리를 고릅니다. 한 번에 여러 ' +
      '품목을 같은 자리로 몰아 추천하지 않기 위해서입니다. 수용량은 보지 않습니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- 6 ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('6. 승인하고 반영하기')] }),
  ...section('승인은 사람만 합니다', [
    body(
      '추천을 만드는 일과 승인하는 일은 권한이 다릅니다. 만드는 것은 원장을 읽어 통계를 내는 ' +
      '분석이라 자동화 에이전트도 할 수 있지만, 승인하는 것은 지게차를 실제로 움직이게 만드는 ' +
      '운영 판단이라 창고관리자·시스템관리자만 할 수 있습니다.',
    ),
    body(
      '아래는 자동화 에이전트 계정으로 같은 화면을 연 모습입니다. 추천 목록은 보이지만 Approve와 ' +
      'Reject 버튼이 아예 없고, 상단에 "조회 전용" 배지가 붙습니다.',
    ),
    ...shot('07-agent-cannot-approve.png', '자동화 에이전트는 추천을 볼 수는 있어도 승인할 수 없다'),
    body(
      '이 제한은 화면이 버튼을 숨기는 것으로 끝나지 않습니다. 다른 경로로 요청해도 데이터베이스가 ' +
      '거부합니다.',
      { italics: true },
    ),
  ]),
  ...section('승인해도 아직 옮겨진 것이 아닙니다', [
    body(
      '창고관리자가 Approve를 누르면 상태가 APPROVED로 바뀌지만, SKU 배정 표는 그대로입니다. ' +
      '아래 화면에서 추천은 승인되었는데 P1은 여전히 순위 20 자리에 있습니다.',
    ),
    ...shot('08-approved-not-yet-applied.png', '승인 직후 — 추천은 APPROVED지만 배정은 아직 바뀌지 않았다'),
    body(
      '승인과 반영을 나눈 것은 의도된 설계입니다. "옮기기로 했지만 야간 작업 때 옮긴다" 같은 ' +
      '중간 상태를 표현할 수 있고, 결정한 시점과 실제로 옮긴 시점이 감사 기록에 따로 남습니다.',
    ),
    body(
      '반려할 때는 사유를 적을 수 있습니다(예: "해당 통로 공사 중"). 반려된 추천은 다시 검토할 수 ' +
      '없지만, 같은 품목에 대해 추천을 새로 생성하는 것은 가능합니다.',
    ),
  ]),
  ...section('Apply를 눌러야 반영됩니다', [
    body(
      '실제로 물건을 옮긴 뒤 Apply를 누르면 배정이 추천 자리로 바뀝니다. 아래 화면에서 P1이 ' +
      '순위 20에서 순위 1로 이동했고, 사유가 SLOTTING_RECOMMENDATION으로 기록되었습니다.',
    ),
    ...shot('09-applied-assignment-moved.png', 'Apply 후 — 배정이 순위 20에서 순위 1로 실제로 옮겨졌다'),
    body(
      '배정이 없던 품목이었다면 이때 배정 기록이 새로 만들어집니다.',
    ),
    body(
      '중요: APPLIED는 "기록이 바뀌었다"는 뜻이지 "물건이 옮겨졌다"는 뜻이 아닙니다. 시스템은 ' +
      '지게차 작업을 배정하지도, 이동 완료 스캔을 확인하지도 않습니다. 그래서 반영할 때마다 ' +
      '"실물 이동은 확인하지 않습니다"라는 안내가 함께 나옵니다.',
      { italics: true },
    ),
    body(
      '실무 요령: 물건을 옮기기 전에 Apply를 누르면 기록과 현실이 어긋납니다. 옮기고 나서 ' +
      '누르세요. 입고담당자에게 이 버튼이 열려 있는 이유가 그것입니다 — 옮겼다는 사실을 아는 ' +
      '사람은 현장에 있습니다.',
    ),
  ]),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- roles ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('누가 무엇을 할 수 있나')] }),
  infoTable([
    ['역할', '이 화면에서 할 수 있는 일'],
    ['WMS_ADMIN (시스템관리자)', '전부'],
    ['WAREHOUSE_MANAGER (창고관리자)', '위치 등록·활성화, 등급 정책 관리, SKU 배정 선언·재배정, 속도 계산, 추천 생성, 추천 승인·반려, 승인된 추천 반영'],
    ['INBOUND_OPERATOR (입고담당자)', 'SKU 배정 선언·재배정, 승인된 추천 반영. 위치·정책 관리와 추천 승인·반려는 불가'],
    ['PROCESS_AGENT (자동화 에이전트)', '속도 계산, 추천 생성만. 승인·반려·반영과 위치·정책 관리는 불가'],
    ['그 외 역할', '조회만'],
  ], 3400),
  new Paragraph({ spacing: { before: 240 }, children: [] }),
  body(
    '경계를 한 문장으로 요약하면 이렇습니다 — 분석은 자동으로 돌려도 되지만, 물건을 옮기라는 ' +
    '결정은 사람이 합니다. 그리고 옮겼다는 기록은 옮긴 사람이 남깁니다.',
    { italics: true },
  ),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- limits ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('이 기능이 하지 않는 일')] }),
  body('기대와 다를 수 있는 부분을 미리 밝혀 둡니다.'),
  bullet('실제 동선이나 이동 거리를 계산하지 않습니다. 접근성 순위라는 사람이 매긴 정수 하나만 봅니다.'),
  bullet('수용량을 검증하지 않습니다. Capacity 칸은 기록용이며, 자리가 좁아서 못 들어가는 경우를 막아 주지 않습니다.'),
  bullet('위험물·온도대 같은 위치-품목 적합성 규칙이 없습니다. 냉장 품목을 상온 자리로 추천할 수도 있으니 승인 단계에서 확인하세요.'),
  bullet('물건을 옮기는 작업을 사람에게 배정하거나 추적하지 않습니다. 반영은 기록만 바꿉니다.'),
  bullet('배정 기록과 실제 창고를 맞춰 보지 않습니다. 어긋나도 알려 주지 않습니다.'),
  bullet('추천을 자동으로 적용하는 경로가 없습니다. 승인 없이 배정이 바뀌는 일은 일어나지 않습니다.'),
  new Paragraph({ spacing: { before: 200 }, children: [] }),
  body(
    '마지막 항목은 제한이 아니라 약속입니다 — 어느 날 아침에 와 보니 시스템이 밤새 물건을 ' +
    '옮기라고 지시해 놓았을 일은 없습니다.',
    { italics: true },
  ),
  new Paragraph({ children: [new PageBreak()] }),

  // ---------------- FAQ / errors ----------------
  new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('자주 만나는 메시지')] }),
  body('화면 상단에 빨간 띠로 표시되는 오류 메시지의 뜻과 대처 방법입니다.'),
  infoTable([
    ['메시지에 포함된 말', '뜻과 대처'],
    ['INVALID: location_code … already exists in this warehouse',
      '같은 창고에 같은 위치 코드가 이미 있습니다. 다른 코드를 쓰거나 기존 위치를 확인하세요.'],
    ['INVALID: storage location … is INACTIVE',
      '비활성화된 자리에 배정하거나 반영하려 했습니다. 먼저 Activate로 되살리거나 다른 자리를 고르세요. 승인 후에 자리가 비활성화된 경우에도 이 오류가 납니다.'],
    ['INVALID: product … already has an active assignment',
      '이미 배정이 있는 품목에 새 배정을 선언하려 했습니다. 표 오른쪽 "이동…" 드롭다운으로 재배정하세요.'],
    ['INVALID: a A class policy already exists for this warehouse',
      '그 등급 정책이 이미 있습니다. 값을 바꾸려면 새로 등록하지 말고 기존 정책을 수정하세요.'],
    ['INVALID: window_end must be after window_start',
      '관찰 종료일이 시작일보다 앞서거나 같습니다.'],
    ['INVALID: velocity batch … has no snapshot in this warehouse',
      '속도 계산 결과가 없는 상태에서 추천을 생성하려 했습니다. Compute Velocity를 먼저 실행하세요.'],
    ['INVALID: recommendation … is not PENDING',
      '이미 승인·반려된 추천을 다시 검토하려 했습니다. 화면을 새로 고쳐 최신 상태를 확인하세요.'],
    ['INVALID: recommendation … is not APPROVED',
      '승인되지 않은(또는 이미 반영된) 추천을 반영하려 했습니다. 승인 없이 배정이 바뀌는 경로는 없습니다.'],
    ['FORBIDDEN: role cannot review slotting recommendations',
      '추천 승인·반려는 창고관리자·시스템관리자만 할 수 있습니다. 물리적 재고 이동을 유발하는 결정이기 때문입니다.'],
    ['FORBIDDEN: role cannot register storage locations',
      '위치 등록은 창고관리자·시스템관리자만 할 수 있습니다. 오른쪽 위 역할 배지를 확인하세요.'],
    ['FORBIDDEN: role cannot compute SKU velocity',
      '현재 역할에는 속도 계산 권한이 없습니다.'],
    ['CONFLICT: expected version …',
      '내가 화면을 열어 둔 사이에 다른 사람이 먼저 이 기록을 바꿨습니다. 화면을 새로 고친 뒤 다시 시도하세요. 덮어쓰기 사고를 막기 위한 정상 동작입니다.'],
  ], 3800),
  new Paragraph({ spacing: { before: 300 }, children: [] }),
  body(
    '이 매뉴얼의 모든 화면은 실제 자동화 테스트(frontend/playwright/e2e/slotting-flow.spec.ts)를 ' +
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
        children: [new TextRun({ text: '슬롯팅 최적화 · 운영자 매뉴얼', size: 18, color: '94A3B8' })],
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
