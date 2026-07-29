"""Supabase clients for the wms schema, authenticated as real demo users so
RLS/role checks inside the wms_* RPCs behave the same way they do for a human
user (see config.py).

Three service identities exist, deliberately kept apart in RLS:

- PROCESS_AGENT (`get_authed_client`) — ProcessGPT telling the WMS what to do.
- WCS_GATEWAY (`get_gateway_client`) — the equipment side reporting back what
  actually happened. Only this identity may call the equipment feedback RPCs
  (design.md D5); it deliberately cannot resolve faults, which needs a human.
- AUDITOR (`get_auditor_client`) — read-only audit/finance identity for the
  natural-language audit log. It is the only one of the three that may call
  wms_query_audit_log / wms_export_audit_log, and it may call nothing else;
  PROCESS_AGENT reading the audit log is refused by the RPC itself.
"""

import logging

from supabase import ClientOptions, create_client

from . import config

logger = logging.getLogger("wms_mcp")


def _sign_in(email: str, password: str, label: str):
    """Return (client, user_id) signed in as the given demo identity.

    Signs in fresh on every call rather than caching a session/refresh-token
    lifecycle — acceptable overhead for demo call volume, avoids expiry bugs.
    """
    if not email or not password:
        raise RuntimeError(f"{label} email/password not configured")

    client = create_client(
        config.SUPABASE_URL,
        config.SUPABASE_ANON_KEY,
        options=ClientOptions(schema="wms"),
    )
    session = client.auth.sign_in_with_password({"email": email, "password": password})
    client.postgrest.auth(session.session.access_token)
    return client, session.user.id


def get_authed_client():
    """Return (client, process_agent_user_id), signed in as the demo process agent."""
    return _sign_in(
        config.WMS_PROCESS_AGENT_EMAIL,
        config.WMS_PROCESS_AGENT_PASSWORD,
        "WMS_PROCESS_AGENT",
    )


def get_gateway_client():
    """Return (client, wcs_gateway_user_id), signed in as the demo WCS gateway."""
    return _sign_in(
        config.WMS_WCS_GATEWAY_EMAIL,
        config.WMS_WCS_GATEWAY_PASSWORD,
        "WMS_WCS_GATEWAY",
    )


_provisioned_tenants: set[str] = set()
_service_role_client = None


def _get_service_role_client():
    """Lazily create the one client in this server that authenticates with
    the Supabase service_role key instead of a signed-in identity.

    wms_ensure_tenant_provisioned is granted to service_role only (not
    authenticated) because it assigns tenant membership/roles by
    caller-supplied email — see the migration's header comment for why that
    can't be left open to any signed-in user on a Supabase project shared
    with ProcessGPT's own production data. Every other RPC in this server
    keeps using the per-identity anon-key clients in this module unchanged.
    """
    global _service_role_client
    if _service_role_client is None:
        _service_role_client = create_client(
            config.SUPABASE_URL,
            config.SUPABASE_SERVICE_ROLE_KEY,
            options=ClientOptions(schema="wms"),
        )
    return _service_role_client


def ensure_tenant_provisioned(tenant_id: str) -> None:
    """Idempotently provision a brand-new ProcessGPT tenant in the wms schema
    (tenant/warehouse/service-identity memberships/demo master data) the
    first time wms-mcp sees it, so a production tenant doesn't need a manual
    seed step before it can call any wms_* tool.

    No-ops with a warning if SUPABASE_SERVICE_ROLE_KEY isn't configured
    (local dev typically relies on supabase/seed.sql instead).

    Cheap to call on every RPC: the DB-side RPC short-circuits immediately
    once the tenant row exists, and this in-process set skips even that
    round trip for tenants already confirmed provisioned by this process.
    """
    if not tenant_id or tenant_id in _provisioned_tenants:
        return
    if not config.SUPABASE_SERVICE_ROLE_KEY:
        logger.warning(
            "SUPABASE_SERVICE_ROLE_KEY not set; skipping auto-provisioning for tenant_id=%s "
            "(wms_* calls will fail with FORBIDDEN/FK errors unless this tenant was seeded another way)",
            tenant_id,
        )
        return
    _get_service_role_client().rpc("wms_ensure_tenant_provisioned", {
        "p_tenant_id": tenant_id,
        "p_process_agent_email": config.WMS_PROCESS_AGENT_EMAIL or None,
        "p_wcs_gateway_email": config.WMS_WCS_GATEWAY_EMAIL or None,
        "p_auditor_email": config.WMS_AUDITOR_EMAIL or None,
    }).execute()
    _provisioned_tenants.add(tenant_id)


def get_auditor_client():
    """Return (client, auditor_user_id), signed in as the demo AUDITOR identity.

    Used only by the two audit-log tools. Signing them in as PROCESS_AGENT
    would simply produce FORBIDDEN — the audit surface accepts WMS_ADMIN and
    AUDITOR only (20260806 D2) — so the tools carry their own identity rather
    than pretending the agent can audit itself.
    """
    return _sign_in(
        config.WMS_AUDITOR_EMAIL,
        config.WMS_AUDITOR_PASSWORD,
        "WMS_AUDITOR",
    )


class WmsCommandError(Exception):
    """Raised when a wms_* RPC returns a CONFLICT:/FORBIDDEN:/INVALID: error
    (see the migration's envelope-error convention)."""

    def __init__(self, kind: str, message: str):
        self.kind = kind  # "CONFLICT" | "FORBIDDEN" | "INVALID" | "UNKNOWN"
        super().__init__(message)


def classify_error(exc: Exception) -> WmsCommandError:
    text = str(exc)
    for kind in ("CONFLICT", "FORBIDDEN", "INVALID"):
        if f"{kind}:" in text:
            return WmsCommandError(kind, text)
    return WmsCommandError("UNKNOWN", text)
