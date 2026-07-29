"""wms-mcp server configuration. See services/office-mcp/office_mcp/config.py
for the .env-loading pattern this mirrors."""

import os
from pathlib import Path


def _load_env_file() -> None:
    root = Path(__file__).resolve().parents[1]
    env_path = root / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key and key not in os.environ:
            os.environ[key] = value


_load_env_file()


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


SUPABASE_URL: str = _env("SUPABASE_URL", "http://127.0.0.1:55321")
SUPABASE_ANON_KEY: str = _env("SUPABASE_ANON_KEY")

# Used ONLY to call wms_ensure_tenant_provisioned (see client.py's
# _service_role_client). Every other RPC in this server signs in as one of
# the three named identities below over the anon key, same as a human user,
# so RLS applies the same way (design.md D3). This key bypasses RLS across
# the WHOLE Supabase project (not just the wms schema) and must never reach
# a browser or be reused for anything else. Optional: if unset, tenant
# auto-provisioning is skipped (fine for local dev, where supabase/seed.sql
# already provisions tenants A/B) and a warning is logged on first RPC call.
SUPABASE_SERVICE_ROLE_KEY: str = _env("SUPABASE_SERVICE_ROLE_KEY")

WMS_PROCESS_AGENT_EMAIL: str = _env("WMS_PROCESS_AGENT_EMAIL")
WMS_PROCESS_AGENT_PASSWORD: str = _env("WMS_PROCESS_AGENT_PASSWORD")

# Equipment-side service identity for the WCS equipment-control contract.
# Symmetric to PROCESS_AGENT but pointed the other way: PROCESS_AGENT tells
# the WMS what to do, WCS_GATEWAY reports back what the equipment did. The
# two roles are kept apart in RLS on purpose (design.md D5), so the reporting
# tools need their own login rather than reusing the process agent's.
WMS_WCS_GATEWAY_EMAIL: str = _env("WMS_WCS_GATEWAY_EMAIL")
WMS_WCS_GATEWAY_PASSWORD: str = _env("WMS_WCS_GATEWAY_PASSWORD")

# Read-only audit/finance identity for the natural-language audit log contract
# (20260806_operations_audit_log.sql). A third identity rather than a reuse of
# PROCESS_AGENT, because the whole point of that contract is that the auditor
# watches the agent and not the other way round: wms_query_audit_log and
# wms_export_audit_log accept WMS_ADMIN / AUDITOR only, and PROCESS_AGENT gets
# FORBIDDEN from the database no matter what the tool allowlist says. AUDITOR
# holds no write role anywhere in the schema.
WMS_AUDITOR_EMAIL: str = _env("WMS_AUDITOR_EMAIL")
WMS_AUDITOR_PASSWORD: str = _env("WMS_AUDITOR_PASSWORD")

SERVER_PORT: int = int(_env("WMS_MCP_PORT", "8199"))


def log_config_summary() -> None:
    import logging
    logger = logging.getLogger("wms_mcp")
    logger.info(
        "wms-mcp config: SUPABASE_URL=%s PORT=%s PROCESS_AGENT_EMAIL=%s WCS_GATEWAY_EMAIL=%s "
        "AUDITOR_EMAIL=%s SERVICE_ROLE_KEY=%s",
        SUPABASE_URL, SERVER_PORT, WMS_PROCESS_AGENT_EMAIL or "(unset)",
        WMS_WCS_GATEWAY_EMAIL or "(unset)", WMS_AUDITOR_EMAIL or "(unset)",
        "(set)" if SUPABASE_SERVICE_ROLE_KEY else "(unset, tenant auto-provisioning disabled)",
    )
