# 10.3–10.5 연동: wms-mcp를 ProcessGPT 테넌트에 등록

> `mcp/` 서버의 9개 도구와 ProcessGPT 폴링 컨테이너에서의 도구 검색을 실제로
> 검증했다. `scripts/install_processgpt_integration.py`는 테넌트 MCP 설정, 제한된
> WMS 실행 에이전트, `wms_replenishment_process` BPMN과 HITL 폼을 반복 실행 가능한
> 방식으로 설치한다.

## 실사 결과 요약 (docs/02-contracts.md §1.3)

`services/completion`은 Odoo를 별도 서비스가 아니라 테넌트별 `tenants.mcp`
JSONB 컬럼의 stdio MCP 서버 항목으로 등록해 사용한다
(`services/completion/mcp.json`의 `"odoo ERP"` 항목, 실행은
`services/completion/polling_service/mcp_processor.py`의
`MultiServerMCPClient`를 통해 이뤄진다). wms-mcp는 stdio가 아니라
streamable-HTTP 서버이므로, `mcpServers` 항목의 transport만 다르고
등록 방식은 동일하다.

## 등록 JSON

`tenants.mcp` (또는 `services/completion/mcp.json` 카탈로그)에 아래 항목을 추가한다.

```json
{
  "wms": {
    "type": "url",
    "url": "http://wms-mcp:8199/mcp",
    "transport": "streamable_http"
  }
}
```

로컬 개발 시 `url`은 `http://127.0.0.1:8199/mcp`. docker-compose에 편입할 때는
`services/frontend/docker-compose/docker-compose.yaml`의 기존 서비스들과 같은
패턴으로 `wms-mcp` 서비스를 추가하고(이미 사용 중인 포트와 겹치지 않게 8199 선택,
실사 결과 참고), 컨테이너 이름으로 `url`을 가리키게 한다.

## 에이전트 tool 허용 목록

해당 테넌트의 자동화 에이전트(예: "재보충 담당 에이전트")가 아래 도구만 쓰도록
scope를 제한한다(design.md D6, §12 `PROCESS_AGENT` 원칙):

```text
wms.get_availability
wms.create_rfq
wms.request_approval
wms.confirm_po
wms.register_arrival
wms.receive
wms.putaway
```

`wms.inspect`(품질 판정)와 `wms.scrap`(폐기)은 RLS에서 이미
`QUALITY_INSPECTOR`/`WMS_ADMIN` 역할만 허용하도록 막혀 있다 — 자동 에이전트가
호출해도 `FORBIDDEN`이 반환된다(migration `wms_record_quality_result`/
`wms_apply_disposition`). 즉 tool 허용 목록에서 빼더라도, 빠졌을 때의 안전망이
DB 레벨에도 있다.

## 10.4/10.5: completion 연동

- **10.4** (`completion_automated-task-execution`): serviceTask의 `tool`을
  `mcp:<tool_name>`으로 지정하면 completion이 해당 도구만 에이전트에 노출한다.
  WMS의 `{result: "ok", document_id, status, version, next_actions}` envelope도
  기존 `{status: "success"}` 형식과 함께 workitem `output`에 보존한다.
- **10.5** (`completion_process-workitem-submission`): 구매 승인 human task는
  `wms_submit_purchase_approval`을 **frontend에서 로그인한 실제 사용자**가
  호출해야 한다(PROCESS_AGENT 역할은 이 RPC를 호출할 권한이 없음, 의도적).
  workitem 제출 시 `po_id`와 `expected_version`을 폼 hidden field로 보존해
  버전 충돌을 감지한다. 데모 프로세스의 승인 폼과 품질 폼에 이 필드가 포함된다.

## 설치

WMS MCP를 호스트의 `8199` 포트에 실행하고 ProcessGPT 로컬 스택이 준비된 상태에서:

```bash
cd services/sample-app-wms
python3 scripts/install_processgpt_integration.py
```

설치되는 실행 흐름:

```text
재고 부족 감지
→ get_availability
→ create_rfq
→ request_approval
→ 발주 승인(HITL)
→ confirm_po
→ register_arrival
→ receive
→ 품질검사(HITL)
→ putaway 또는 폐기 확인
```

설치 스크립트는 기존 `tenants.mcp` 항목을 보존한 채 `wms`만 병합하며, 기존
프로세스 인스턴스나 WMS 거래 데이터를 삭제하지 않는다.

## 로컬 검증 기록

`mcp/main.py`를 기동한 상태에서 fastmcp `Client`로 `get_availability` →
`create_rfq` → `request_approval` 3개 도구를 순서대로 호출해 실제 Postgres
왕복(가용재고 조회 → RFQ 생성 → 사람 승인 필요 여부 반환)을 확인했다. 전체
9개 RPC는 psql로 직접 호출해 happy path, 교차 테넌트 RLS 차단, 잘못된 역할
FORBIDDEN, 낙관적 동시성 CONFLICT, 멱등성(동일 키 재호출 시 중복 생성 없음)을
모두 확인했다.
