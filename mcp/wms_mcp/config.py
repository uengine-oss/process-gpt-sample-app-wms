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

WMS_PROCESS_AGENT_EMAIL: str = _env("WMS_PROCESS_AGENT_EMAIL")
WMS_PROCESS_AGENT_PASSWORD: str = _env("WMS_PROCESS_AGENT_PASSWORD")

SERVER_PORT: int = int(_env("WMS_MCP_PORT", "8199"))


def log_config_summary() -> None:
    import logging
    logger = logging.getLogger("wms_mcp")
    logger.info(
        "wms-mcp config: SUPABASE_URL=%s PORT=%s PROCESS_AGENT_EMAIL=%s",
        SUPABASE_URL, SERVER_PORT, WMS_PROCESS_AGENT_EMAIL or "(unset)",
    )
