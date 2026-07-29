#!/usr/bin/env python3
"""Provision one trainee's WMS tenant for the multi-tenant demo.

Run once per trainee by the instructor/admin — NOT something wms-mcp or
wms-frontend does on the trainee's behalf. wms.wms_ensure_tenant_provisioned
is granted to service_role only, precisely so this step stays an explicit,
trusted admin action rather than something any signed-in user can trigger
for any tenant_id (see supabase/migrations/20260807_wms_tenant_auto_provisioning.sql
for why — this Supabase project is shared with ProcessGPT's own production
users once deployed).

Idempotent: safe to re-run for the same tenant (e.g. to add the trainee's
membership after wms-mcp already auto-provisioned the tenant from an MCP
call, or to fix a typo'd email) — it never re-creates the tenant/warehouse/
demo data, and role grants are on-conflict-do-nothing.

Usage:
    python3 scripts/onboard_trainee.py \\
        --tenant-id acme-trainee-07 \\
        --trainee-email trainee07@example.com \\
        [--tenant-name "Trainee 07"] \\
        [--role WMS_ADMIN]

Reads SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY and the three shared
service-identity emails from mcp/.env by default (same file wms-mcp itself
reads); override with --env-file or plain environment variables.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def read_env_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tenant-id", required=True, help="ProcessGPT tenant_id for this trainee")
    parser.add_argument("--trainee-email", required=True, help="Trainee's ProcessGPT/Supabase Auth login email")
    parser.add_argument("--tenant-name", default=None, help="Display name; defaults to tenant-id")
    parser.add_argument("--role", default="WMS_ADMIN", help="wms role granted to the trainee (default WMS_ADMIN)")
    parser.add_argument(
        "--env-file",
        default=str(Path(__file__).resolve().parents[1] / "mcp" / ".env"),
        help="Path to a .env file providing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / WMS_*_EMAIL",
    )
    args = parser.parse_args()

    env = {**read_env_file(Path(args.env_file)), **os.environ}

    supabase_url = env.get("SUPABASE_URL", "").rstrip("/")
    service_role_key = env.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not supabase_url or not service_role_key:
        raise SystemExit(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required (via --env-file or the environment)."
        )

    payload = {
        "p_tenant_id": args.tenant_id,
        "p_tenant_name": args.tenant_name,
        "p_trainee_email": args.trainee_email,
        "p_trainee_role": args.role,
        "p_process_agent_email": env.get("WMS_PROCESS_AGENT_EMAIL") or None,
        "p_wcs_gateway_email": env.get("WMS_WCS_GATEWAY_EMAIL") or None,
        "p_auditor_email": env.get("WMS_AUDITOR_EMAIL") or None,
    }

    req = Request(
        f"{supabase_url}/rest/v1/rpc/wms_ensure_tenant_provisioned",
        data=json.dumps(payload).encode(),
        headers={
            "apikey": service_role_key,
            "Authorization": f"Bearer {service_role_key}",
            "Content-Type": "application/json",
            "Accept-Profile": "wms",
            "Content-Profile": "wms",
        },
        method="POST",
    )
    try:
        with urlopen(req, timeout=30) as response:
            response.read()
    except HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise SystemExit(f"wms_ensure_tenant_provisioned failed ({exc.code}): {detail}") from exc

    print(
        f"Provisioned tenant '{args.tenant_id}' and granted {args.trainee_email} role={args.role}. "
        f"Trainee entry URL: https://<wms-frontend-host>/t/{args.tenant_id}"
    )


if __name__ == "__main__":
    main()
