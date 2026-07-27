"""WCS gateway simulator — the external worker of `wms_wcs-digital-twin-simulation`.

WHY THIS IS A PROCESS AND NOT A pg_cron JOB (design.md D2)
----------------------------------------------------------
`wms_report_command_result` authorises through `wms.has_role(...)`, which reads
`auth.uid()` — the `sub` claim of a real Supabase Auth session. A database-side
scheduler has no session; `auth.uid()` is null there, and the only way around
that is to forge `request.jwt.claims`, which is precisely the trust boundary
area 1 D5 drew. So the clock lives out here, in a process that *actually signs
in* as the seeded `WCS_GATEWAY` identity (`wcs-gateway-a@demo.local`) and calls
the RPCs over PostgREST — exactly the calls a real PLC/WCS bridge would make.

WHAT IT DOES (design.md "외부 워커 프로세스", 5 steps)
-----------------------------------------------------
Per tick, per (tenant, warehouse) in scope:

  1. `wms_get_due_simulation_actions` returns both halves of the work in one
     round trip: `unplanned_commands` (live commands on simulated equipment with
     no plan yet) and `due_actions` (plans whose `next_run_at` has arrived).
  2. every unplanned command gets `wms_plan_simulated_command` — idempotent, so
     two workers or a restart cannot double-roll the dice.
  3. every due action gets `wms_advance_simulated_command`, which internally
     calls area 1's real `wms_report_command_result`. That is what makes areas
     2-5's triggers (work-order propagation, sortation outcome validation, JAM
     escalation, per-item palletising propagation) fire for a simulated machine
     exactly as they would for a real one.
  4. transient errors are logged and retried on the next tick; the plan itself
     lives in `wms.simulation_command_schedules`, so a crashed or restarted
     worker resumes without losing or duplicating a step (design.md D3).

The worker holds no state of its own. Killing it mid-command and starting it
again finishes that command.

RUNNING IT
----------
    cd services/sample-app-wms/mcp
    .venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --once
    .venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --loop --interval 1

`--once` is a *drain* pass: plan everything outstanding, then keep advancing
(sleeping until the next scheduled step) until no plan is left or
`--max-seconds` runs out. That makes a single invocation enough to take a
freshly dispatched command all the way to COMPLETED, which is what the
Playwright spec and the demo scripts rely on. Use `--tick` for a literal
single poll with no waiting.

`--loop` is the real background mode: poll forever every `--interval` seconds.

Credentials come from `mcp/.env` (`WMS_WCS_GATEWAY_EMAIL` /
`WMS_WCS_GATEWAY_PASSWORD` / `SUPABASE_URL` / `SUPABASE_ANON_KEY`) through
`wms_mcp.config`, i.e. the same file the MCP server reads. No new secret and no
new service role — area 1's `WCS_GATEWAY` is reused verbatim (design.md D9).
"""

from __future__ import annotations

import argparse
import logging
import sys
import time
import uuid
from dataclasses import dataclass

from ..client import get_gateway_client

logger = logging.getLogger("wms_mcp.simulator")

# How long a --once drain waits before giving up on plans that never come due.
DEFAULT_MAX_SECONDS = 60.0
# Never sleep longer than this in a drain, so a plan created mid-drain is seen.
MAX_SLEEP = 2.0


@dataclass(frozen=True)
class Scope:
    tenant_id: str
    warehouse_id: str

    def __str__(self) -> str:  # noqa: D105
        return f"{self.tenant_id[:8]}/{self.warehouse_id[:8]}"


@dataclass
class TickResult:
    planned: int = 0
    advanced: int = 0
    completed: int = 0
    errors: int = 0
    # earliest next_run_at still outstanding, as an epoch offset in seconds
    outstanding: int = 0

    def __iadd__(self, other: "TickResult") -> "TickResult":
        self.planned += other.planned
        self.advanced += other.advanced
        self.completed += other.completed
        self.errors += other.errors
        self.outstanding += other.outstanding
        return self

    @property
    def did_something(self) -> bool:
        return bool(self.planned or self.advanced)


class GatewaySimulator:
    """Signs in once as WCS_GATEWAY and drives simulated equipment."""

    def __init__(self, scopes: list[Scope] | None = None) -> None:
        self._client = None
        self._user_id: str | None = None
        self._scopes: list[Scope] | None = scopes

    # -- session -----------------------------------------------------------

    def connect(self) -> None:
        """(Re)establish the Supabase Auth session. Safe to call again after an
        expiry — client.py signs in fresh every time rather than refreshing."""
        self._client, self._user_id = get_gateway_client()
        logger.info("signed in as WCS_GATEWAY user_id=%s", self._user_id)

    def _rpc(self, name: str, params: dict):
        return self._client.rpc(name, params).execute().data

    # -- scope discovery ---------------------------------------------------

    def discover_scopes(self) -> list[Scope]:
        """Every (tenant, warehouse) this gateway identity can actually see.

        Reads its own membership rows (RLS: `user_id = auth.uid()`) and asks
        `wms.current_warehouse_ids` per tenant — the same two calls the Vue app's
        auth store makes. Nothing is hard-coded, so the worker follows the seed
        data instead of duplicating it.
        """
        if self._scopes is not None:
            return self._scopes

        memberships = self._client.table("memberships").select("tenant_id, role").execute().data or []
        scopes: list[Scope] = []
        for m in memberships:
            tenant_id = m["tenant_id"]
            warehouse_ids = self._rpc("current_warehouse_ids", {"p_tenant_id": tenant_id}) or []
            for warehouse_id in warehouse_ids:
                scopes.append(Scope(tenant_id, warehouse_id))
        self._scopes = scopes
        logger.info("scope: %s", ", ".join(str(s) for s in scopes) or "(none)")
        return scopes

    # -- one poll ----------------------------------------------------------

    def tick(self) -> TickResult:
        total = TickResult()
        for scope in self.discover_scopes():
            total += self._tick_scope(scope)
        return total

    def _tick_scope(self, scope: Scope) -> TickResult:
        result = TickResult()
        try:
            board = self._rpc("wms_get_due_simulation_actions", {
                "p_tenant_id": scope.tenant_id,
                "p_warehouse_id": scope.warehouse_id,
                "p_as_of": None,  # server-side now()
            })
        except Exception as exc:  # noqa: BLE001 — one bad scope must not kill the loop
            logger.warning("[%s] poll failed: %s", scope, exc)
            result.errors += 1
            return result

        # 1. plan whatever arrived since the last tick (idempotent server-side)
        for cmd in board.get("unplanned_commands", []):
            try:
                plan = self._rpc("wms_plan_simulated_command", {
                    "p_command_id": cmd["command_id"],
                    "p_actor_id": self._user_id,
                    "p_idempotency_key": str(uuid.uuid4()),
                    "p_correlation_id": "wcs-gateway-simulator",
                })
                result.planned += 1
                logger.info(
                    "[%s] planned %s %s -> %s at %s (terminal %s)",
                    scope, cmd["command_type"], cmd["command_id"][:8],
                    plan["next_status"], plan["next_run_at"], plan["planned_terminal_status"],
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("[%s] plan %s failed: %s", scope, cmd["command_id"][:8], exc)
                result.errors += 1

        # 2. advance whatever is due
        for action in board.get("due_actions", []):
            try:
                step = self._rpc("wms_advance_simulated_command", {
                    "p_command_id": action["command_id"],
                    "p_actor_id": self._user_id,
                    "p_idempotency_key": str(uuid.uuid4()),
                    "p_correlation_id": "wcs-gateway-simulator",
                })
                result.advanced += 1
                warnings = step.get("warnings") or []
                if not step.get("plan_remaining"):
                    result.completed += 1
                logger.info(
                    "[%s] %s %s -> %s%s",
                    scope, action["command_type"], action["command_id"][:8],
                    step.get("reported_status") or step.get("status"),
                    f" {warnings}" if warnings else "",
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("[%s] advance %s failed: %s", scope, action["command_id"][:8], exc)
                result.errors += 1

        result.outstanding += self._outstanding(scope)
        return result

    def _outstanding(self, scope: Scope) -> int:
        """Plans still live for this scope — the drain's stop condition."""
        try:
            status = self._rpc("wms_get_simulation_schedule_status", {
                "p_tenant_id": scope.tenant_id,
                "p_warehouse_id": scope.warehouse_id,
                "p_equipment_id": None,
                "p_due_only": False,
            })
            return int(status.get("count", 0))
        except Exception as exc:  # noqa: BLE001
            logger.warning("[%s] schedule status failed: %s", scope, exc)
            return 0

    # -- run modes ---------------------------------------------------------

    def drain(self, max_seconds: float = DEFAULT_MAX_SECONDS, poll: float = 0.25) -> TickResult:
        """Plan everything outstanding, then keep ticking until no plan is left.

        Used by `--once`: one invocation takes a freshly dispatched command all
        the way to its terminal state, so tests and demos do not have to babysit
        a background process.
        """
        deadline = time.monotonic() + max_seconds
        total = TickResult()
        while True:
            step = self.tick()
            total.planned += step.planned
            total.advanced += step.advanced
            total.completed += step.completed
            total.errors += step.errors
            total.outstanding = step.outstanding

            if step.outstanding == 0:
                break
            if time.monotonic() >= deadline:
                logger.warning(
                    "drain gave up after %.0fs with %d plan(s) still outstanding",
                    max_seconds, step.outstanding,
                )
                break
            time.sleep(min(poll, MAX_SLEEP))
        return total

    def loop(self, interval: float) -> None:
        """Poll forever. Ctrl-C to stop; nothing is lost — the plans are in the DB."""
        logger.info("polling every %.2fs — Ctrl-C to stop", interval)
        while True:
            try:
                self.tick()
            except Exception as exc:  # noqa: BLE001 — including an expired session
                logger.warning("tick failed, re-authenticating: %s", exc)
                try:
                    self.connect()
                except Exception as reconnect_exc:  # noqa: BLE001
                    logger.error("re-authentication failed: %s", reconnect_exc)
            time.sleep(interval)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wcs_gateway_simulator",
        description="WCS_GATEWAY software simulator for equipment flagged is_simulated.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true",
                      help="drain pass: plan and advance until no plan is left, then exit (default)")
    mode.add_argument("--tick", action="store_true",
                      help="literal single poll — plan and advance only what is due right now")
    mode.add_argument("--loop", action="store_true",
                      help="poll continuously (real background mode)")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="seconds between polls in --loop mode (default 1.0)")
    parser.add_argument("--max-seconds", type=float, default=DEFAULT_MAX_SECONDS,
                        help="wall-clock budget for a --once drain (default 60)")
    parser.add_argument("--tenant-id", help="restrict to one tenant (default: every tenant in scope)")
    parser.add_argument("--warehouse-id", help="restrict to one warehouse; requires --tenant-id")
    parser.add_argument("-q", "--quiet", action="store_true", help="warnings and errors only")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.WARNING if args.quiet else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        # stdout, not the default stderr: the run log is the artifact this
        # process produces, and `... > simulator-worker-run.txt` should catch it.
        stream=sys.stdout,
    )
    # one INFO line per PostgREST call would bury the simulation log
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("hpack").setLevel(logging.WARNING)

    if args.warehouse_id and not args.tenant_id:
        print("--warehouse-id requires --tenant-id", file=sys.stderr)
        return 2

    scopes = None
    if args.tenant_id and args.warehouse_id:
        scopes = [Scope(args.tenant_id, args.warehouse_id)]

    sim = GatewaySimulator(scopes=scopes)
    sim.connect()
    if args.tenant_id and not args.warehouse_id:
        # tenant given but not warehouse: expand through the same RPC the app uses
        ids = sim._rpc("current_warehouse_ids", {"p_tenant_id": args.tenant_id}) or []
        sim._scopes = [Scope(args.tenant_id, w) for w in ids]

    if args.loop:
        try:
            sim.loop(args.interval)
        except KeyboardInterrupt:
            logger.info("stopped")
        return 0

    if args.tick:
        result = sim.tick()
    else:
        result = sim.drain(max_seconds=args.max_seconds)

    logger.info(
        "done: planned=%d advanced=%d finished=%d errors=%d outstanding=%d",
        result.planned, result.advanced, result.completed, result.errors, result.outstanding,
    )
    return 1 if result.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
