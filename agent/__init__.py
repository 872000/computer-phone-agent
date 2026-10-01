"""Computer/Phone Agent — multi-app workflow automation layer.

Built on top of the PhoneAgent JSON-RPC bridges (iOS XCTest server and
Android adb bridge). This package turns single device actions into
repeatable, auditable multi-app workflows:

- ``workflows``   — YAML workflow definition format + validation
- ``runner``      — sequential workflow executor with backends
- ``guardrails``  — safety policy for destructive actions
- ``session_log`` — JSONL audit log of every action and result
"""

__version__ = "0.2.0"
