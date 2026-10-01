"""Safety guardrails for the Computer/Phone Agent.

A phone/computer agent can tap through real apps — deleting photos,
uninstalling apps, buying things, sending messages. This module is the
policy layer that sits between a workflow step and execution:

- :data:`DESTRUCTIVE_ACTIONS` — actions that are never run silently.
- :func:`is_destructive` — classify a step.
- :func:`check_step` — enforce the policy; raises
  :class:`GuardrailViolation` when a destructive step lacks explicit
  ``confirm: true``. The runner logs every approval in the session log,
  so destructive runs stay auditable.
"""

from __future__ import annotations

from typing import Any, Dict


class GuardrailViolation(Exception):
    """Raised when a workflow step violates the safety policy."""


# Actions that change the world outside the device session in a way that
# is hard or impossible to undo. These always require `confirm: true`.
DESTRUCTIVE_ACTIONS = frozenset(
    {
        # data loss / device state
        "delete",
        "remove",
        "uninstall",
        "erase",
        "wipe",
        "format",
        "factory_reset",
        "reset_all_settings",
        # money
        "purchase",
        "buy",
        "pay",
        "subscribe",
        "transfer",
        "send_money",
        # outward communication
        "send_message",
        "send_sms",
        "post",
        "publish",
        "share",
    }
)

# Param keys/values that hint at destruction even when the action name
# itself is generic (e.g. `tap` on a "Delete" button is flagged when the
# workflow author labels it so via params).
_DESTRUCTIVE_HINTS = ("delete", "uninstall", "erase", "format", "factory_reset")


def is_destructive(action: str, params: Dict[str, Any] | None = None) -> bool:
    """Return True if the action/params look destructive."""
    if action in DESTRUCTIVE_ACTIONS:
        return True
    for value in (params or {}).values():
        text = str(value).lower()
        if any(hint in text for hint in _DESTRUCTIVE_HINTS):
            return True
    return False


def check_step(step: Dict[str, Any]) -> None:
    """Enforce the guardrail policy for one workflow step.

    Raises GuardrailViolation if the step is destructive and does not
    carry explicit ``confirm: true``.
    """
    action = step.get("action", "")
    params = step.get("params") or {}
    if is_destructive(action, params) and step.get("confirm") is not True:
        raise GuardrailViolation(
            f"step {step.get('name')!r} uses destructive action {action!r} "
            "but is missing explicit 'confirm: true'. Refusing to run."
        )


def summarize_policy() -> str:
    """Human-readable one-liner describing the policy."""
    return (
        f"{len(DESTRUCTIVE_ACTIONS)} destructive actions "
        "(delete/uninstall/purchase/send/…) require explicit 'confirm: true' "
        "and are recorded in the session log."
    )
