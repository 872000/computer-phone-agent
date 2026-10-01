# Computer/Phone Agent

> **Evolution of PhoneAgent** — from single-device RPC actions to a general
> computer/mobile agent that completes **multi-app workflows**.
>
> PhoneAgent gave us the device bridges (iOS XCTest server, Android adb
> bridge, the shared RPC action surface). This project adds the layer on
> top that makes those primitives composable, safe, and auditable:
>
> - **Workflow definitions (YAML)** — declare a multi-step task once:
>   steps with `app`, `action`, `params`, and `on_error` policies. The
>   `app` field makes workflows hop between apps automatically
>   (`agent/workflows.py`).
> - **Sequential runner** — executes steps in order with per-step status
>   (`ok` / `failed` / `skipped` / `blocked`), `abort` / `retry` /
>   `continue` error policies, and pluggable backends: `DryRunBackend`
>   for authoring/testing without a device, `RpcBackend` for the real
>   bridges (`agent/runner.py`).
> - **Safety guardrails** — destructive actions (`delete`, `uninstall`,
>   `purchase`, `send_message`, …) require explicit `confirm: true` in
>   the step and are recorded as approved in the session log; anything
>   else is blocked before it touches the device (`agent/guardrails.py`).
> - **Session log (JSONL)** — every action and result is logged for
>   audit and replay (`agent/session_log.py`).
>
> ```bash
> # author & test a workflow with no device attached
> python3 -m agent.runner run examples/sample_workflow.yaml --dry-run
>
> # run it against a real bridge (iOS simulator / Android emulator)
> python3 -m agent.runner run my_flow.yaml --host 127.0.0.1 --port 45678
> ```
>
> See [CHANGELOG.md](CHANGELOG.md) for what changed versus upstream
> PhoneAgent.
>
> ---

# PhoneAgent

PhoneAgent is an experimental mobile automation project with two operating modes:

1. **In-app iPhone agent** (SwiftUI app + XCTest runner + OpenAI Responses API)
2. **External bridge** to let Codex/OpenClaw control iOS/Android devices

The bridge supports both:
- **iOS** (XCTest-hosted actions against simulator or physical iPhone)
- **Android** (adb + UiAutomator + input/screencap actions against emulator or device)

## Demo

- [Self contained iOS app](https://www.youtube.com/shorts/4rnv6dN-2Lg)
- [OpenClaw controlling an iPhone](https://youtube.com/shorts/MMAjh1xqsdM?feature=share)
- [OpenClaw controlling an Android phone](https://www.youtube.com/shorts/gN7ZJtl0byM)
- [Codex controlling an iPhone](https://youtu.be/D44AWOQI74I)

## What This Repo Includes

- **iOS app UI**: API key entry, prompt input, microphone support, settings, always-on wake-word mode
- **iOS test-hosted RPC server**: newline-delimited JSON-RPC on port `45678`
- **Android RPC server**: localhost JSON-RPC bridge backed by `adb` commands
- **Helper scripts**:
  - iOS bridge launcher + physical-device localhost forwarding
  - Android bridge launcher (with adb auto-discovery)
  - generic RPC CLI (`rpc.py`) for both platforms

## Capabilities

### Shared RPC action surface (iOS + Android)

- `get_tree`
- `get_screen_image`
- `get_context`
- `set_api_key`
- `open_app`
- `tap`
- `tap_element`
- `enter_text`
- `scroll`
- `swipe`
- `stop`

### iOS-only RPC method

- `submit_prompt`

`submit_prompt` powers the in-app iPhone agent loop.

### In-app iPhone agent features

- OpenAI API key stored in Keychain
- Prompt submission from keyboard or microphone
- Optional always-on mode with custom wake word
- Notification completion + quick-reply follow-up loop

## Requirements

### macOS host

- Xcode (for iOS app/UITest bridge)
- Python 3
- Android SDK tools (`adb`) for Android bridge

### Devices

- iOS simulator or physical iPhone (Developer setup)
- Android emulator or physical Android device (USB debugging or wireless debugging)

## Quick Start (In-App iPhone Agent)

1. Open `/Users/rounak/Developer/PhoneAgent-cli/PhoneAgent.xcodeproj` in Xcode.
2. Run the `PhoneAgent` scheme on an iPhone/simulator.
3. Enter OpenAI API key when prompted.
4. Submit tasks via keyboard or microphone.

## Quick Start (AI Agents)

For Codex/OpenClaw usage, use the skill docs:
- [`.agents/skills/phoneagent/`](./.agents/skills/phoneagent/)

### Send RPC calls

```bash
# iOS bundle identifier example
./.agents/skills/phoneagent/scripts/rpc.py open-app com.apple.Preferences

# Android package example
./.agents/skills/phoneagent/scripts/rpc.py open-app com.android.settings

# Fetch tree
./.agents/skills/phoneagent/scripts/rpc.py get-tree

# Capture screenshot (writes PNG under /tmp/phoneagent-artifacts)
./.agents/skills/phoneagent/scripts/rpc.py get-screen-image --print-metadata
```

The CLI supports `--host` and `--port` if you need non-default endpoint settings.

## RPC Notes

- Transport: newline-delimited JSON-RPC objects
- Endpoint: `127.0.0.1:45678` by default
- `open_app` request parameter is `bundle_identifier`:
  - iOS: pass bundle identifier (e.g. `com.apple.Preferences`)
  - Android: pass package name (e.g. `com.android.settings`)
- `tap_element` / `enter_text` use coordinate rectangles in format `{{x, y}, {w, h}}`

## Common App Identifiers

### iOS

- Settings: `com.apple.Preferences`
- Camera: `com.apple.camera`
- Photos: `com.apple.mobileslideshow`
- Messages: `com.apple.MobileSMS`
- Home Screen: `com.apple.springboard`

## Wireless Android (No USB)

```bash
# Pair (from Wireless debugging screen)
adb pair <PHONE_IP:PAIRING_PORT>

# Connect (from Wireless debugging screen)
adb connect <PHONE_IP:ADB_PORT>

# Verify
adb devices -l
```

Then start Android bridge with that network serial:

```bash
./.agents/skills/phoneagent/scripts/start_android_rpc_bridge_local.sh --serial <PHONE_IP:ADB_PORT>
```

## Security Model

- RPC bridge is localhost-oriented (`127.0.0.1`)
- iOS physical-device workflow uses localhost forwarding
- Android bridge executes only through selected `adb` serial
- In-app API key is stored in iOS Keychain

## Repository Pointers

- iOS app entry: `PhoneAgent/PhoneAgentApp.swift`
- iOS app UI/state: `PhoneAgent/ContentView.swift`, `PhoneAgent/PromptView.swift`, `PhoneAgent/SettingsView.swift`
- iOS bridge server: `PhoneAgentUITests/SimulatorRPCServer.swift`, `PhoneAgentUITests/PhoneAgent.swift`
- RPC CLI: `.agents/skills/phoneagent/scripts/rpc.py`
- iOS bridge launcher: `.agents/skills/phoneagent/scripts/start_rpc_bridge_local.sh`
- Android bridge launcher: `.agents/skills/phoneagent/scripts/start_android_rpc_bridge_local.sh`
- Android bridge server: `.agents/skills/phoneagent/scripts/android_rpc_bridge.py`

## Known Limitations

- Android bridge does **not** yet implement `submit_prompt` agent loop
- UI tree snapshots can be noisy/stale during animations
- Keyboard/text reliability can vary by app and platform
- Long-running tasks may require explicit polling/retries

## Disclaimer

- Experimental software
- Personal project
- App contents may be sent to OpenAI API when using agent flow
- Model/tool actions can be incorrect; verify important operations
