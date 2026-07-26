# 10.3–10.5 연동: wms-mcp를 ProcessGPT 테넌트에 등록

> 이 슬라이스에서 실제로 검증한 것: `mcp/` 서버가 fastmcp `Client`로 9개 도구를
> streamable-HTTP(`/mcp`)로 정상 호출됨(로컬 스모크 테스트, 아래 참고). 이 문서는
> 그 서버를 실제 ProcessGPT 인스턴스(`services/completion`)의 테넌트 MCP 설정에
> 등록하는 절차다 — main `process-gpt` 리포의 completion/polling-service까지
> 함께 띄운 통합 테스트는 이번 슬라이스 범위에 포함하지 않았다(별도 세션 필요).

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

## 10.4/10.5: completion 연동 지점 (설계만, 미구현)

- **10.4** (`completion_automated-task-execution`): serviceTask가 위 도구를
  호출한 뒤 반환된 `{result, document_id, status, next_actions}`를 workitem
  `output`에 그대로 기록하면 된다 — 이미 `MCPProcessor.execute_mcp_tools`가
  임의의 MCP 도구 결과를 `output`에 저장하는 구조이므로 wms-mcp 쪽 추가 작업은
  필요 없다. `next_actions`는 다음 활동의 프롬프트 힌트로 활용 가능.
- **10.5** (`completion_process-workitem-submission`): 구매 승인 human task는
  `wms_submit_purchase_approval`을 **frontend에서 로그인한 실제 사용자**가
  호출해야 한다(PROCESS_AGENT 역할은 이 RPC를 호출할 권한이 없음, 의도적).
  workitem 제출 시 `po_id`와 `expected_version`을 폼 hidden field로 보존해
  버전 충돌을 감지해야 한다 — 아직 이 필드들을 completion workitem 스키마에
  매핑하는 코드는 작성하지 않았다(TODO).

## 로컬 검증 기록

`mcp/main.py`를 기동한 상태에서 fastmcp `Client`로 `get_availability` →
`create_rfq` → `request_approval` 3개 도구를 순서대로 호출해 실제 Postgres
왕복(가용재고 조회 → RFQ 생성 → 사람 승인 필요 여부 반환)을 확인했다. 전체
9개 RPC는 psql로 직접 호출해 happy path, 교차 테넌트 RLS 차단, 잘못된 역할
FORBIDDEN, 낙관적 동시성 CONFLICT, 멱등성(동일 키 재호출 시 중복 생성 없음)을
모두 확인했다.
