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
