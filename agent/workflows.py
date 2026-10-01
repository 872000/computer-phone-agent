"""Workflow definition format for the Computer/Phone Agent.

A workflow is a YAML document describing a repeatable multi-app task::

    name: morning-settings-check
    description: Open Settings, inspect the tree, take a screenshot.
    platform: ios            # ios | android | any
    app: com.apple.Preferences   # default app for steps that omit `app`
    steps:
      - name: open-settings
        app: com.apple.Preferences
        action: open_app
        params: {}
      - name: read-ui-tree
        action: get_tree
        on_error: retry
        max_retries: 2
      - name: screenshot
        action: get_screen_image

Step fields
-----------
- ``name`` (required): human-readable step identifier, unique in the workflow.
- ``action`` (required): RPC method, e.g. ``open_app``, ``tap``,
  ``tap_element``, ``enter_text``, ``scroll``, ``swipe``, ``get_tree``,
  ``get_screen_image``, ``get_context``, ``stop``.
- ``app`` (optional): bundle id (iOS) or package name (Android). When set
  and different from the previously opened app, the runner issues an
  ``open_app`` call before the step's action. This is what makes a
  workflow span multiple apps.
- ``params`` (optional): dict of parameters for the action.
- ``on_error`` (optional): ``abort`` (default), ``retry`` or ``continue``.
- ``max_retries`` (optional): attempts after the first when
  ``on_error: retry`` (default 1).
- ``confirm`` (optional): must be ``true`` for destructive actions —
  see :mod:`agent.guardrails`.

Supported actions are the union of the shared RPC surface
(``get_tree``, ``get_screen_image``, ``get_context``, ``set_api_key``,
``open_app``, ``tap``, ``tap_element``, ``enter_text``, ``scroll``,
``swipe``, ``stop``), the iOS-only ``submit_prompt``, and the
policy-covered destructive actions in :mod:`agent.guardrails`
(``delete``, ``purchase``, ``send_message``, …) so future device
actions validate today.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

import yaml

from .guardrails import DESTRUCTIVE_ACTIONS

ON_ERROR_POLICIES = ("abort", "retry", "continue")
PLATFORMS = ("ios", "android", "any")

# Union of the shared RPC action surface, the iOS-only agent-loop action,
# and the policy-covered destructive actions (forward-compatible: new
# device actions the agent layer may add later).
KNOWN_ACTIONS = frozenset(
    {
        "get_tree",
        "get_screen_image",
        "get_context",
        "set_api_key",
        "open_app",
        "tap",
        "tap_element",
        "enter_text",
        "scroll",
        "swipe",
        "stop",
        "submit_prompt",
    }
    | DESTRUCTIVE_ACTIONS
)


def load_workflow(path: str | Path) -> Dict[str, Any]:
    """Load and validate a workflow YAML file. Raises ValueError on problems."""
    data = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    errors = validate_workflow(data)
    if errors:
        raise ValueError("Invalid workflow:\n- " + "\n- ".join(errors))
    return data


def validate_workflow(data: Any) -> List[str]:
    """Return a list of validation errors (empty means valid)."""
    errors: List[str] = []
    if not isinstance(data, dict):
        return ["workflow must be a mapping"]

    if not data.get("name"):
        errors.append("missing required field: name")

    platform = data.get("platform", "any")
    if platform not in PLATFORMS:
        errors.append(f"platform must be one of {PLATFORMS}, got {platform!r}")

    steps = data.get("steps")
    if not isinstance(steps, list) or not steps:
        errors.append("workflow must define a non-empty 'steps' list")
        return errors

    seen = set()
    for i, step in enumerate(steps):
        where = f"steps[{i}]"
        if not isinstance(step, dict):
            errors.append(f"{where}: step must be a mapping")
            continue
        name = step.get("name")
        if not name:
            errors.append(f"{where}: missing required field: name")
        elif name in seen:
            errors.append(f"{where}: duplicate step name {name!r}")
        else:
            seen.add(name)

        action = step.get("action")
        if not action:
            errors.append(f"{where}: missing required field: action")
        elif action not in KNOWN_ACTIONS:
            errors.append(f"{where}: unknown action {action!r}")

        on_error = step.get("on_error", "abort")
        if on_error not in ON_ERROR_POLICIES:
            errors.append(
                f"{where}: on_error must be one of {ON_ERROR_POLICIES}, got {on_error!r}"
            )

        max_retries = step.get("max_retries", 1)
        if not isinstance(max_retries, int) or max_retries < 0:
            errors.append(f"{where}: max_retries must be a non-negative int")

        params = step.get("params", {})
        if params is not None and not isinstance(params, dict):
            errors.append(f"{where}: params must be a mapping")

    return errors


def sample_workflow() -> Dict[str, Any]:
    """Return the 3-step sample workflow used by the smoke test."""
    return {
        "name": "sample-settings-tour",
        "description": "Open iOS Settings, read the UI tree, capture a screenshot.",
        "platform": "ios",
        "app": "com.apple.Preferences",
        "steps": [
            {
                "name": "open-settings",
                "app": "com.apple.Preferences",
                "action": "open_app",
            },
            {
                "name": "read-ui-tree",
                "action": "get_tree",
                "on_error": "retry",
                "max_retries": 1,
            },
            {
                "name": "screenshot",
                "action": "get_screen_image",
            },
        ],
    }
