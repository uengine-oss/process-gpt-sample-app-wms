# 멀티테넌시 데모 배포: wms를 ProcessGPT SaaS에 얹기

이 문서는 이 저장소를 실제 서버에 올려, 각자의 테넌트를 가진 여러 교육생이
자신의 ProcessGPT 계정으로 wms-frontend(게이트웨이 경유)에 로그인해 데모
데이터를 확인하고, ProcessGPT로 돌아가 wms-mcp를 연동해 AI 에이전트로 WMS를
조작하는 실습을 세팅하는 절차다.

## 아키텍처 요약

- **DB**: 새 Supabase 프로젝트를 만들지 않는다. ProcessGPT가 이미 쓰는 그
  운영 Supabase SaaS 프로젝트에 `wms` 스키마를 얹는다. 그래서 `tenant_id`가
  ProcessGPT의 tenant_id와 그대로 일치하고(`20260727010000_wms_tenant_id_to_text.sql`),
  Auth도 공유되어 트레이니가 ProcessGPT에 로그인한 세션을 wms-frontend에서도
  그대로 쓸 수 있다(SSO).
- **wms-frontend / wms-mcp**: 이 저장소의 `frontend/`, `mcp/`를 각각 Docker
  이미지로 빌드해 서버에 올린다(`docker-compose.yml` 참고). 둘 다 stateless라
  서버 자체에는 상태가 없다 — 모든 상태는 Supabase에 있다.
- **게이트웨이**: ProcessGPT 쪽에서 트레이니를 wms-frontend로 안내하는
  역할이며, 이 저장소 밖에서 구현한다. wms-frontend는 게이트웨이가 지켜야
  할 진입 계약만 제공한다 — 아래 "게이트웨이 진입 계약" 참고.

## 0. 전제

- 대상 Supabase 프로젝트에 대한 `service_role` 키(대시보드 → Project
  Settings → API)와 `anon` 키.
- 배포할 서버(도커 사용 가능한 VM 등)와 wms-frontend/wms-mcp를 리버스
  프록시로 노출할 도메인/TLS 설정(이 저장소는 TLS를 종단하지 않는다).

## 1. 마이그레이션을 운영 Supabase 프로젝트에 적용

```bash
cd supabase
supabase link --project-ref <프로젝트 참조>
supabase db push   # 이 저장소의 supabase/migrations/*를 적용
```

`wms` 스키마만 새로 생기고 ProcessGPT의 기존 스키마/테이블은 건드리지
않는다. `supabase/seed.sql`은 로컬 전용이라 여기서 실행하지 않는다 —
운영 데이터는 3장의 자동 프로비저닝과 4장의 트레이니 온보딩으로 만든다.

## 2. 공유 서비스 아이덴티티 3개 생성

`PROCESS_AGENT` / `WCS_GATEWAY` / `AUDITOR`는 모든 테넌트가 공유하는
고정 로그인이다(로컬 데모의 `process-agent-a@demo.local` 등과 같은 역할,
운영에서는 이 프로젝트의 Supabase Auth에 실제로 만든다). Supabase 대시보드
→ Authentication → Add user로 3개 계정을 만들고(또는 Admin API), 이메일과
비밀번호를 5단계의 `mcp/.env.prod`에 넣는다. 이 세 계정은 특정 테넌트에
속하지 않는다 — `wms.memberships`에서의 소속은 테넌트가 생길 때마다
`wms_ensure_tenant_provisioned`가 부여한다(3장).

## 3. 테넌트 자동 프로비저닝 (wms-mcp가 처리)

`wms.wms_ensure_tenant_provisioned` RPC가 브랜드 뉴 tenant_id를 처음 보는
순간 tenant/warehouse/데모 마스터데이터와 세 서비스 아이덴티티의 멤버십을
멱등적으로 만든다(`20260807_wms_tenant_auto_provisioning.sql`). wms-mcp가
모든 도구 호출에서 이걸 자동으로 호출하므로(`mcp/wms_mcp/client.py`의
`ensure_tenant_provisioned`) 테넌트별 수동 시드가 필요 없다 — **단, 이건
사람 트레이니 계정에는 아무 권한도 주지 않는다.** 트레이니 본인이
wms-frontend에서 뭔가를 보려면 4단계가 필요하다.

이 RPC는 `service_role`에만 실행 권한이 있다(`authenticated`에는 없음) —
호출자가 지정하는 이메일에게 그대로 역할을 부여하는 함수라, 이 프로젝트가
ProcessGPT의 실제 운영 사용자와 같은 프로젝트를 쓰는 이상 아무 로그인
사용자나 호출할 수 있게 열어두면 테넌트 ID를 알거나 추측하는 것만으로
남의 테넌트에 자기 자신을 WMS_ADMIN으로 부여할 수 있다. 그래서 wms-mcp는
이 한 호출에 한해 `SUPABASE_SERVICE_ROLE_KEY`로 인증하는 별도 클라이언트를
쓴다 — 이 저장소의 다른 모든 RPC 호출은 여전히 `design.md D3` 그대로
익명 키 + 실제 로그인 세션으로 이뤄진다.

## 4. 트레이니 온보딩 (교육생 1명당 1회, 강사가 실행)

```bash
python3 scripts/onboard_trainee.py \
  --tenant-id <ProcessGPT tenant_id> \
  --trainee-email <트레이니의 ProcessGPT 로그인 이메일> \
  --tenant-name "<표시 이름>" \
  --env-file mcp/.env.prod
```

멱등적이라 재실행해도 안전하다(이미 있는 테넌트/역할은 건드리지 않고,
빠진 것만 채운다). 이 스크립트가 하는 일은 3장과 같은 RPC를 호출하되
`p_trainee_email`을 함께 넘겨 그 사람에게 `WMS_ADMIN`(기본값) 멤버십과
전체 창고 스코프를 부여하는 것뿐이다 — 이게 3장과 별도 단계인 이유는
"어떤 ProcessGPT 로그인이 이 테넌트의 진짜 주인인가"를 아는 것은 강사/운영자
뿐이고, wms-frontend나 wms-mcp가 자체적으로 그 판단을 대신하면 위 3장 마지막
문단의 취약점이 그대로 트레이니 계정에도 열리기 때문이다.

## 5. wms-frontend / wms-mcp 배포

```bash
cp .env.example .env                 # SUPABASE_URL / SUPABASE_ANON_KEY (wms-frontend용)
cp mcp/.env.example mcp/.env.prod    # 전체 설정 (SUPABASE_URL/ANON_KEY/SERVICE_ROLE_KEY, 3개 서비스 아이덴티티, 포트)
# .env, mcp/.env.prod를 실제 값으로 채운다. 특히 SERVICE_ROLE_KEY는
# mcp/.env.prod에만 넣는다 — 절대 .env(프론트엔드, 브라우저로 나감)에 넣지 않는다.

docker compose build
docker compose up -d
```

TLS 종단 리버스 프록시(Caddy/Traefik/nginx 등)를 그 앞에 둔다. wms-mcp는
ProcessGPT 폴링 컨테이너가 도달할 수 있는 URL(`https://<도메인>/mcp` 등)로
노출해야 한다.

## 6. 게이트웨이 라우팅 + SSO (process-gpt-vue3)

실제 게이트웨이는 `process-gpt-vue3`의 Spring Cloud Gateway
(`gateway/src/main/resources/application.yml`)다. `*.process-gpt.io` 전체가
이 하나의 서비스로 들어와 `Path` predicate로 내부 서비스에 분기하고 접두사를
벗겨서(`RewritePath`) 넘긴다 — `/completion/**`, `/memento/**` 등과 같은
패턴으로 `/wms/**` → wms-frontend, `/wms-mcp/**` → wms-mcp 라우트를 추가했다
(`gateway/src/main/resources/application.yml`, `default`/`docker` 프로파일
둘 다, K8s 매니페스트는 `kubernetes/deployment.yaml`/`service.yaml`).

SSO는 별도 토큰 핸드오프 라우트가 필요 없다 — wms-frontend가
`<tenant>.process-gpt.io/wms`로 ProcessGPT와 **같은 origin**에서 뜨기
때문이다. ProcessGPT 프론트엔드가 로그인 시 `access_token`/`refresh_token`을
`domain=.process-gpt.io` 쿠키로 심어두므로
(`process-gpt-vue3/src/utils/StorageBaseSupabase.js`의 `writeUserData`),
wms-frontend는 `document.cookie`에서 그대로 읽어
`supabase.auth.setSession()`을 호출한다(`frontend/src/stores/auth.ts`의
`restoreSession`) — ProcessGPT 자체의 `StorageBaseSupabase.isConnection()`과
같은 패턴이다.

테넌트 ID는 URL 경로가 아니라 **서브도메인**에서 정한다 —
`process-gpt-vue3/src/main.ts`의 `setupTenant()`와 정확히 같은 알고리즘을
`frontend/src/lib/tenant.ts`의 `getTenantIdFromHost()`가 그대로 복제한다
(subdomain이 `www`/`process-gpt`면 메인 사이트, `localhost`/`192.168`/
`127.0.0.1`이면 `'localhost'`, 그 외엔 첫 서브도메인 라벨). 게이트웨이의
`ForwardHostHeaderFilter`가 서브도메인과 세션 JWT의
`app_metadata.tenant_id`가 일치하는지 이미 검증하므로, wms-frontend도 같은
값을 신뢰할 수 있다 — 서브도메인 → JWT claim → 첫 멤버십 순으로 폴백한다
(`auth.ts`의 `loadContext`). 실제 접근 제어는 항상 RLS(`wms.memberships`)가
하므로 이 순서는 UX일 뿐 보안 경계가 아니다.

로그인 실패 시(세션/쿠키 없음 등) 기존 `/login` 이메일·비밀번호 폼으로
폴백한다.

## 7. ProcessGPT에 wms-mcp 등록

`scripts/install_processgpt_integration.py`는 원래 로컬 개발용 단일
`"localhost"` 테넌트 전용이었지만, `--tenant-id`/`--warehouse-id`/`--sku`/
`--owner-email`을 받도록 일반화해 두었다 — 트레이니별로 그대로 재사용할 수
있다:

```bash
python3 scripts/install_processgpt_integration.py \
  --processgpt-url https://<ProcessGPT Supabase project>.supabase.co \
  --mcp-url https://<wms-mcp 도메인>/mcp \
  --tenant-id <ProcessGPT tenant_id> \
  --warehouse-id <4단계 onboard_trainee.py 출력의 warehouse id> \
  --owner-email <트레이니의 ProcessGPT 로그인>
```

이 스크립트는 ProcessGPT 자체의 `SERVICE_ROLE_KEY`(wms Supabase 프로젝트의
것과 다름 — ProcessGPT의 `public` 스키마에 직접 쓴다)를 `--env-file`(기본
`.env`) 또는 환경변수로 필요로 한다. `tenants.mcp`에 `wms` 서버를 병합하고,
그 테넌트 전용 WMS 실행 에이전트·재보충 프로세스 정의·HITL 폼 3종을
설치한다 — 멱등적이라 재실행해도 안전하다.

직접 관리 화면/API로 등록하려면 `tenants.mcp`에 아래 항목만 추가해도
MCP 연동 자체는 동작한다(단, 에이전트/프로세스는 별도로 만들어야 한다) —
형식은 `docs/03-processgpt-integration.md` "등록 JSON"/"에이전트 tool
허용 목록"과 동일하다:

```json
{
  "wms": {
    "type": "url",
    "url": "https://<wms-mcp 도메인>/mcp",
    "transport": "streamable_http"
  }
}
```

## 실습 흐름 (교육생 관점)

1. ProcessGPT 계정으로 로그인 → 게이트웨이를 통해 wms-frontend 진입(6장의
   `/sso` 또는 `/t/:tenantId`) → 자신의 테넌트 데모 데이터 확인.
2. ProcessGPT로 돌아가 (이미 7장에서 등록된) `wms` MCP 도구가 붙은 에이전트와
   채팅하거나 `wms_replenishment_process` 같은 프로세스를 실행 → 에이전트가
   `tenant_id`를 넘겨 wms 도구 호출 → 3장의 자동 프로비저닝이 이미 끝나
   있으므로(1단계에서 트레이니가 로그인할 때 테넌트가 있었다면 4단계에서
   이미 프로비저닝됨) 바로 재고 조회/RFQ 생성 등이 동작한다.
