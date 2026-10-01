"""Sequential multi-app workflow runner for the Computer/Phone Agent.

Usage::

    python3 -m agent.runner run examples/sample_workflow.yaml --dry-run
    python3 -m agent.runner run my_flow.yaml --host 127.0.0.1 --port 45678

The runner executes workflow steps in order, tracking the currently open
app so a single workflow can hop between apps (the ``app`` field on a
step triggers an ``open_app`` call when it differs from the current app).

Backends
--------
- :class:`DryRunBackend` — no device needed; returns canned successes.
  Used for authoring and testing workflows.
- :class:`RpcBackend` — talks to the real PhoneAgent JSON-RPC bridges
  (newline-delimited JSON over TCP, same protocol as
  ``.agents/skills/phoneagent/scripts/rpc.py``).

Safety
------
Every step passes through :mod:`agent.guardrails` before execution. A
destructive step without ``confirm: true`` is *blocked*: it is logged,
skipped, and the run aborts (unless its ``on_error`` says otherwise).

Error handling per step (``on_error``): ``abort`` (default), ``retry``
(up to ``max_retries``), or ``continue`` (skip and move on).
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path
from typing import Any, Dict, Protocol

from . import guardrails
from .session_log import SessionLog
from .workflows import load_workflow, sample_workflow


class Backend(Protocol):
    def call(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        ...


class DryRunBackend:
    """No-device backend for authoring and testing workflows."""

    def call(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        if method == "get_tree":
            return {"ok": True, "tree": "<dry-run UI tree>"}
        if method == "get_screen_image":
            return {"ok": True, "image": "<dry-run screenshot>"}
        if method == "get_context":
            return {"ok": True, "context": "<dry-run context>"}
        return {"ok": True, "dry_run": True, "method": method, "params": params}


class RpcBackend:
    """Backend for the real PhoneAgent JSON-RPC bridges (iOS + Android)."""

    def __init__(self, host: str = "127.0.0.1", port: int = 45678,
                 timeout_s: float = 30.0):
        self.host = host
        self.port = port
        self.timeout_s = timeout_s
        self._req_id = 0

    def call(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        self._req_id += 1
        payload = (
            json.dumps(
                {"id": self._req_id, "method": method, "params": params}
            )
            + "\n"
        ).encode("utf-8")
        try:
            sock = socket.create_connection((self.host, self.port), timeout=5.0)
        except Exception as e:
            raise RuntimeError(
                f"cannot reach RPC bridge at {self.host}:{self.port}: {e}"
            ) from e
        with sock:
            sock.settimeout(self.timeout_s)
            sock.sendall(payload)
            buf = bytearray()
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                nl = chunk.find(b"\n")
                if nl != -1:
                    buf.extend(chunk[:nl])
                    break
                buf.extend(chunk)
                if len(buf) > 10 * 1024 * 1024:
                    raise RuntimeError("RPC response exceeded 10 MiB")
        resp = json.loads(bytes(buf).decode("utf-8"))
        if isinstance(resp, dict) and resp.get("error"):
            raise RuntimeError(f"RPC error: {resp['error']}")
        return resp if isinstance(resp, dict) else {"ok": True, "result": resp}


class WorkflowRunner:
    """Executes a validated workflow dict step by step."""

    def __init__(self, backend: Backend, log: SessionLog | None = None):
        self.backend = backend
        self.log = log
        self.current_app: str | None = None

    # -- internals -----------------------------------------------------
    def _emit_step(self, **fields: Any) -> None:
        if self.log:
            self.log.log_step(**fields)

    def _switch_app(self, app: str, dry_run: bool) -> None:
        if self.log:
            self.log.log_event("app_switch", app=app)
        self.backend.call("open_app", {"bundle_identifier": app})
        self.current_app = app

    def _execute_action(self, action: str, params: Dict[str, Any]) -> Dict[str, Any]:
        if action == "open_app" and "bundle_identifier" not in params:
            # allow the `app` shorthand to fill in the identifier
            raise RuntimeError("open_app step needs params.bundle_identifier or step.app")
        return self.backend.call(action, params)

    # -- public API ----------------------------------------------------
    def run(self, workflow: Dict[str, Any], *, dry_run: bool = False) -> Dict[str, Any]:
        steps = workflow["steps"]
        default_app = workflow.get("app")
        results: Dict[str, str] = {}
        totals: Dict[str, int] = {}

        if self.log:
            self.log.session_start(workflow, dry_run=dry_run)

        for step in steps:
            name = step["name"]
            action = step["action"]
            app = step.get("app", default_app)
            params = dict(step.get("params") or {})
            on_error = step.get("on_error", "abort")
            max_retries = step.get("max_retries", 1)

            # 1. guardrails before anything touches the device
            try:
                guardrails.check_step(step)
            except guardrails.GuardrailViolation as e:
                self._emit_step(
                    name=name, action=action, app=app, status="blocked",
                    error=str(e),
                )
                results[name] = "blocked"
                totals["blocked"] = totals.get("blocked", 0) + 1
                if self.log:
                    self.log.log_event("guardrail_block", step=name, error=str(e))
                break  # a blocked destructive step always stops the run

            destructive = guardrails.is_destructive(action, params)
            if destructive and self.log:
                self.log.log_event("guardrail_approved", step=name, action=action)

            # 2. hop between apps when the workflow spans them
            if app and app != self.current_app:
                try:
                    self._switch_app(app, dry_run)
                except Exception as e:
                    self._emit_step(
                        name=name, action=action, app=app, status="failed",
                        error=f"open_app failed: {e}",
                    )
                    results[name] = "failed"
                    totals["failed"] = totals.get("failed", 0) + 1
                    if on_error == "abort":
                        break
                    continue

            # 3. execute with retry policy
            status = "failed"
            error: str | None = None
            result: Any = None
            attempts = 1 + (max_retries if on_error == "retry" else 0)
            for attempt in range(1, attempts + 1):
                started = time.monotonic()
                try:
                    if action == "open_app":
                        open_params = dict(params)
                        open_params.setdefault("bundle_identifier", app or "")
                        result = self.backend.call("open_app", open_params)
                        if app:
                            self.current_app = app
                    else:
                        result = self._execute_action(action, params)
                    status = "ok"
                    self._emit_step(
                        name=name, action=action, app=app, status="ok",
                        attempt=attempt,
                        duration_s=time.monotonic() - started,
                        result=_summarize(result),
                        guardrail_approved=destructive,
                    )
                    break
                except Exception as e:  # noqa: BLE001 — surfaced in the log
                    error = f"{type(e).__name__}: {e}"
                    if attempt < attempts:
                        self._emit_step(
                            name=name, action=action, app=app, status="retried",
                            attempt=attempt,
                            duration_s=time.monotonic() - started,
                            error=error,
                        )
                        if self.log:
                            self.log.log_event(
                                "retry", step=name, attempt=attempt, error=error
                            )
                    else:
                        self._emit_step(
                            name=name, action=action, app=app, status="failed",
                            attempt=attempt,
                            duration_s=time.monotonic() - started,
                            error=error,
                            guardrail_approved=destructive,
                        )

            results[name] = status
            totals[status] = totals.get(status, 0) + 1

            if status == "failed" and on_error == "abort":
                if self.log:
                    self.log.log_event("abort", step=name, error=error)
                break
            # on_error == "continue" falls through to the next step

        if self.log:
            self.log.session_end(totals)
        return {"workflow": workflow.get("name"), "results": results, "totals": totals}


def _summarize(result: Any) -> Any:
    """Keep bulky results (UI trees, images) out of the log."""
    if isinstance(result, dict):
        out = {}
        for key, value in result.items():
            if key in ("tree", "image") and isinstance(value, str) and len(value) > 200:
                out[key] = value[:200] + f"… <truncated {len(value)} chars>"
            else:
                out[key] = value
        return out
    return result


# -- CLI ---------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Run a Computer/Phone Agent multi-app workflow."
    )
    sub = p.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="run a workflow YAML file")
    run.add_argument("workflow", help="path to workflow YAML (or 'sample')")
    run.add_argument("--dry-run", action="store_true",
                     help="simulate without touching a device")
    run.add_argument("--host", default="127.0.0.1", help="RPC bridge host")
    run.add_argument("--port", type=int, default=45678, help="RPC bridge port")
    run.add_argument("--log", default=None,
                     help="session log path (default: logs/<workflow>-<ts>.jsonl)")
    run.add_argument("--print-log", action="store_true",
                     help="print the session log path when done")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "run":
        if args.workflow == "sample":
            workflow = sample_workflow()
        else:
            try:
                workflow = load_workflow(args.workflow)
            except (ValueError, OSError) as e:
                print(f"error: {e}", file=sys.stderr)
                return 2

        backend: Backend = (
            DryRunBackend()
            if args.dry_run
            else RpcBackend(args.host, args.port)
        )
        log_path = args.log or str(
            Path("logs")
            / f"{workflow.get('name', 'workflow')}-{int(time.time())}.jsonl"
        )
        with SessionLog(log_path) as log:
            runner = WorkflowRunner(backend, log)
            outcome = runner.run(workflow, dry_run=args.dry_run)

        print(json.dumps(outcome, indent=2))
        if args.print_log:
            print(f"log: {log_path}")
        failed = outcome["totals"].get("failed", 0) + outcome["totals"].get("blocked", 0)
        return 1 if failed else 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
