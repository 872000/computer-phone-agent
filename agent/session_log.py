"""JSONL session log for the Computer/Phone Agent.

Every workflow run writes one JSON object per line:

- ``session_start`` — workflow name, platform, dry-run flag
- ``step`` — per-step attempt: name, action, app, status, duration,
  result summary or error, guardrail approval when applicable
- ``event`` — free-form runner events (app switches, retries, aborts)
- ``session_end`` — totals by status

The log is the audit trail *and* the replay source: :func:`replay`
rebuilds the step sequence from a log file so a run can be reviewed or
re-executed later.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterator, List


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


class SessionLog:
    """Append-only JSONL log for a single workflow run."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = self.path.open("a", encoding="utf-8")

    def _write(self, record: Dict[str, Any]) -> None:
        record.setdefault("ts", _utcnow())
        self._fh.write(json.dumps(record, default=str) + "\n")
        self._fh.flush()

    def session_start(self, workflow: Dict[str, Any], *, dry_run: bool) -> None:
        self._write(
            {
                "type": "session_start",
                "workflow": workflow.get("name"),
                "description": workflow.get("description"),
                "platform": workflow.get("platform", "any"),
                "step_count": len(workflow.get("steps", [])),
                "dry_run": dry_run,
            }
        )

    def log_step(
        self,
        *,
        name: str,
        action: str,
        app: str | None,
        status: str,
        attempt: int = 1,
        duration_s: float = 0.0,
        result: Any = None,
        error: str | None = None,
        guardrail_approved: bool = False,
    ) -> None:
        self._write(
            {
                "type": "step",
                "name": name,
                "action": action,
                "app": app,
                "status": status,  # ok | failed | skipped | blocked | retried
                "attempt": attempt,
                "duration_s": round(duration_s, 3),
                "result": result,
                "error": error,
                "guardrail_approved": guardrail_approved,
            }
        )

    def log_event(self, event: str, **fields: Any) -> None:
        self._write({"type": "event", "event": event, **fields})

    def session_end(self, summary: Dict[str, int]) -> None:
        self._write({"type": "session_end", "summary": summary})

    def close(self) -> None:
        if not self._fh.closed:
            self._fh.close()

    def __enter__(self) -> "SessionLog":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()


def iter_records(path: str | Path) -> Iterator[Dict[str, Any]]:
    """Yield parsed JSON records from a session log."""
    with Path(path).open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line)


def replay(path: str | Path) -> Dict[str, Any]:
    """Rebuild a run summary from a session log file.

    Returns the workflow name, ordered step outcomes, and totals —
    everything needed to review a run or drive a re-execution.
    """
    steps: List[Dict[str, Any]] = []
    totals: Dict[str, int] = {}
    workflow: str | None = None
    for record in iter_records(path):
        if record["type"] == "session_start":
            workflow = record.get("workflow")
        elif record["type"] == "step" and record.get("status") != "retried":
            steps.append(
                {
                    "name": record["name"],
                    "action": record["action"],
                    "app": record["app"],
                    "status": record["status"],
                }
            )
            totals[record["status"]] = totals.get(record["status"], 0) + 1
    return {"workflow": workflow, "steps": steps, "totals": totals}
