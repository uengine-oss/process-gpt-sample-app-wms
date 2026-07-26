"""Supabase client for the wms schema, authenticated as the demo
PROCESS_AGENT user so RLS/role checks inside the wms_* RPCs behave the
same way they do for a human user (see config.py)."""

import logging

from supabase import ClientOptions, create_client

from . import config

logger = logging.getLogger("wms_mcp")


def get_authed_client():
    """Return (client, process_agent_user_id), signed in as the demo process agent.

    Signs in fresh on every call rather than caching a session/refresh-token
    lifecycle — acceptable overhead for demo call volume, avoids expiry bugs.
    """
    if not config.WMS_PROCESS_AGENT_EMAIL or not config.WMS_PROCESS_AGENT_PASSWORD:
        raise RuntimeError("WMS_PROCESS_AGENT_EMAIL/PASSWORD not configured")

    client = create_client(
        config.SUPABASE_URL,
        config.SUPABASE_ANON_KEY,
        options=ClientOptions(schema="wms"),
    )
    session = client.auth.sign_in_with_password({
        "email": config.WMS_PROCESS_AGENT_EMAIL,
        "password": config.WMS_PROCESS_AGENT_PASSWORD,
    })
    client.postgrest.auth(session.session.access_token)
    return client, session.user.id


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
