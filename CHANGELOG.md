# Changelog

## 0.2.0 — Computer/Phone Agent (2026-10-01)

Evolution of upstream [PhoneAgent](https://github.com/rounak/PhoneAgent)
toward a general computer/mobile agent capable of completing multi-app
workflows.

### Added

- `agent/workflows.py` — YAML workflow definition format: named steps
  with `app`, `action`, `params`, `on_error` (`abort`/`retry`/`continue`),
  `max_retries`, and `confirm`; validation with clear error messages;
  the known action set covers the shared RPC surface plus the
  policy-covered destructive actions so future device actions validate
  today.
- `agent/runner.py` — sequential `WorkflowRunner` with per-step status
  (`ok`/`failed`/`skipped`/`blocked`), automatic `open_app` when a step's
  `app` differs from the current app (multi-app hopping), retry/abort/
  continue error handling, pluggable backends:
  - `DryRunBackend` — device-free authoring and testing.
  - `RpcBackend` — newline-delimited JSON-RPC over TCP, the same
    protocol as `.agents/skills/phoneagent/scripts/rpc.py`.
  - CLI: `python3 -m agent.runner run <workflow.yaml> [--dry-run]`.
- `agent/guardrails.py` — safety policy: 21 destructive actions
  (delete/uninstall/factory_reset/purchase/send_message/…) require
  explicit `confirm: true`; violations raise `GuardrailViolation`,
  block the step, and abort the run. Approvals are recorded in the
  session log.
- `agent/session_log.py` — append-only JSONL session log
  (`session_start`/`step`/`event`/`session_end`) plus `replay()` to
  rebuild a run summary for audit or re-execution.
- `examples/sample_workflow.yaml` — 3-step sample workflow (open
  Settings → read UI tree → screenshot), smoke-tested in dry-run mode.

### Notes

- The 55 MB `demo.MOV` from upstream was intentionally excluded to keep
  the repo lean; the YouTube demo links in the README remain.
- All upstream sources (iOS app, XCTest bridge, Android bridge,
  `rpc.py`, launchers) are otherwise unchanged.

## 0.1.0 — Upstream PhoneAgent (as cloned)

- Experimental iPhone agent (SwiftUI app + XCTest runner + OpenAI
  Responses API).
- External bridge for Codex/OpenClaw to control iOS/Android devices.
- Shared RPC action surface: `get_tree`, `get_screen_image`,
  `get_context`, `set_api_key`, `open_app`, `tap`, `tap_element`,
  `enter_text`, `scroll`, `swipe`, `stop` (+ iOS-only `submit_prompt`).
