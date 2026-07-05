# mobile-mcp iOS evaluation — Vocello

Research and rollout guide for [mobile-next/mobile-mcp](https://github.com/mobile-next/mobile-mcp)
as the **primary agent-facing iOS driver** on a paired physical iPhone. Replaces mirroir +
Peekaboo mirror-coordinate driving for agent UI work while keeping
[`scripts/ios_device.sh`](../../scripts/ios_device.sh) as build/install/pull/gate authority.

Related: [on-device-ui-testing-research-report.md](on-device-ui-testing-research-report.md),
[computer-use-mcp-alternatives-cursor.md](computer-use-mcp-alternatives-cursor.md),
[ios-device-testing.md](ios-device-testing.md) Playbook F.

---

## Executive summary

| Lane | Driver | Recommendation |
| --- | --- | --- |
| Pre-merge gates (near term) | XCUITest `test` / `gate` | **Keep** |
| UI bench matrix (XCUITest) | `bench-ui` | **Keep as fallback** |
| Agent UI bench matrix | **mobile-mcp** (`bench-ui-mcp`) | **Adopt** (replaces `bench-ui-vision`) |
| Exploratory Studio tours | **mobile-mcp** | **Adopt** |
| Engine / RTF proof | headless `bench` autorun | **Unchanged** |
| Mirror observation | `ios_device.sh shot` | **Keep** (no taps) |
| macOS exploratory | Peekaboo | **Unchanged** |

**Hard rule:** MLX engine tests run on **real device only** — never mobile-mcp iOS Simulator
for Vocello engine work ([`AGENTS.md`](../../AGENTS.md) Hard rules).

---

## Why the previous stack was a mess

1. **Three “eyes”** — XCTest AX (gates), mirroir OCR (vision), Peekaboo Mac AX on mirror chrome.
2. **Mirror taps are indirect** — coordinate bridge ([`scripts/lib/ios_vision_bridge.sh`](../../scripts/lib/ios_vision_bridge.sh)); Generate vs chip collisions in vision pilot.
3. **Policy sprawl** — Playbooks A–E, `bench-ui`, `bench-ui-vision`, overlapping MCP routing.
4. **Automation mutex** — XCUITest attach, WDA, and mirror taps must not run concurrently.

mobile-mcp uses **WebDriverAgent + accessibility tree** on the phone — same identifier surface as
XCUITest, agent-friendly MCP tools.

---

## mobile-mcp at a glance

- **npm:** `@mobilenext/mobile-mcp` (pin version in `~/.cursor/mcp.json`, not `@latest`)
- **Tools:** `mobile_list_elements_on_screen`, `mobile_launch_app`, `mobile_type_keys`, taps/swipes, screenshots
- **iOS real device:** WDA on phone + `go-ios` tunnel/forward (port 8100) + signed runner
- **Telemetry:** set `MOBILEMCP_DISABLE_TELEMETRY=1`
- **Cursor:** use [`mcp_stdio_wrapper.sh`](computer-use-mcp-alternatives-cursor.md) like Peekaboo/mirroir

### Vocello-critical identifiers (spike must find via WDA)

From [`ui-test-surface.md`](ui-test-surface.md) / [`ios-app-guide.md`](ios-app-guide.md):

| Surface | Identifiers |
| --- | --- |
| Tabs | `rootTab_studio`, `rootTab_voices`, `rootTab_history`, `rootTab_settings` |
| Mode segments | `generateSection_custom`, `generateSection_design`, `generateSection_clone` |
| Generate flow | `textInput_textEditor`, `textInput_generateButton` |
| Bench hooks | `iosStudio_benchClearScript` (when `QWENVOICE_UI_TEST_HOOKS=1`) |

---

## Phase 1 spike checklist

Run on a **paired physical iPhone** with Vocello installed from this repo.

### One-time setup

- [ ] Xcode CLT + paired device (Developer Mode, trust Mac)
- [ ] `npm install -g mobilecli` ([Mobile Next iOS docs](https://mobilenext.ai/docs/mobile-mcp/getting-started-ios))
- [ ] `go-ios` installed (`brew install go-ios` or [release binary](https://github.com/danielpaulus/go-ios/releases) → `~/.local/bin/ios`)
- [ ] WDA agent signed + installed:
  - Wildcard profile: `mobilecli agent install --device <id> --provisioning-profile ~/path/to.profile`
  - Or explicit App ID `com.mobilenext.devicekit-iosUITests.xctrunner`
- [ ] Add to `~/.cursor/mcp.json` (via wrapper, literal home path):

```json
"mobile-mcp": {
  "command": "/Users/you/.cursor/bin/mcp_stdio_wrapper.sh",
  "args": ["-y", "@mobilenext/mobile-mcp@0.0.61"],
  "env": {
    "MOBILEMCP_DISABLE_TELEMETRY": "1"
  }
}
```

- [ ] Tunnel + forward (until mobilecli automates — keep terminals open):
  - `ios tunnel start --userspace`
  - `ios forward 8100 8100`
- [ ] Launch WDA (Xcode Test on WebDriverAgentRunner, or mobilecli when available)

### Preflight (repo)

```sh
scripts/ios_mobile_mcp.sh preflight
scripts/ios_device.sh models check --strict
```

### Spike steps (agent)

1. `mobile_list_available_devices` — device listed
2. `scripts/ios_device.sh build && scripts/ios_device.sh install`
3. `scripts/ios_mobile_mcp.sh lock` — automation mutex (no concurrent XCUITest)
4. `mobile_launch_app` → `com.patricedery.vocello`
5. `mobile_list_elements_on_screen` — **PASS** if `generateSection_custom`, `rootTab_studio`, `textInput_generateButton` appear
6. One generation: type medium corpus → Generate → `scripts/ios_device.sh vision-bench-wait` (or pull)
7. `scripts/ios_mobile_mcp.sh unlock`

### Pass criteria

| Check | Pass |
| --- | --- |
| WDA responds on :8100 | `preflight` exit 0 |
| Studio identifiers in element list | ≥3 required ids above |
| Generate without coordinate-only workflow | Agent uses tree or label, not blind x,y |
| Telemetry row after one take | `engine/generations.jsonl` row with expected `mode` |

Record results in `build/ios/mobile-mcp-spike/spike-result.json` (template from `scripts/ios_mobile_mcp.sh spike-record`).

### Spike status (2026-07-04)

Initial agent session recorded **`fail`** — operator must complete one-time WDA setup
(`mobilecli`, `go-ios`, tunnel/forward, signed runner) before re-running Phase 1. See
`build/ios/mobile-mcp-spike/spike-result.json`. Re-record with
`scripts/ios_mobile_mcp.sh spike-record --pass` when identifiers appear in WDA tree.

---

## Phase 2 — bench-ui-mcp

Preferred agent matrix lane (replaces `bench-ui-vision`):

```sh
scripts/ios_device.sh device-state
scripts/ios_mobile_mcp.sh preflight
scripts/ios_device.sh bench-ui-mcp --agent-drive \
  --warm 1 --lengths medium --modes custom --label mcp-pilot
```

Same telemetry gate as XCUITest `bench-ui`: [`check_ios_ui_bench.py`](../../scripts/check_ios_ui_bench.py).

**Deprecated:** `bench-ui-vision` (mirroir + Peekaboo) — alias retained; do not extend.

---

## Phase 4 — gate comparison (XCUITest vs mobile-mcp)

Before swapping pre-merge gates to mobile-mcp:

```sh
# After XCUITest bench-ui run (baseline dir):
scripts/ios_mobile_mcp.sh compare-bench \
  build/ios/bench-ui-<xcuitest-runID>/ \
  build/ios/bench-ui-mcp-<mcp-runID>/
```

Compares per-cell RTF, audioQC, and row counts from pulled `generations.jsonl`. Manual listening pass still required for release QA.

---

## Risks

| Risk | Mitigation |
| --- | --- |
| WDA signing | One-time mobilecli + team profile (private ops doc) |
| Tunnel/forward manual | `ios_mobile_mcp.sh preflight`; track mobile-mcp roadmap |
| Cursor MCP stdio respawn | SSE `--listen` mode or shell-owned WDA lifecycle |
| XCUITest + WDA conflict | `ios_mobile_mcp.sh lock` / `unlock` mutex |
| Simulator misuse | MCP routing ban; real device only |
| Clone mic enrollment | Human on device or XCTest — not mobile-mcp primary |

---

## Decision log

| Date | Decision |
| --- | --- |
| 2026-07 | Adopt mobile-mcp as primary **agent** iOS driver; keep XCUITest gates near term |
| 2026-07 | Deprecate mirroir+Peekaboo **UI driving**; mirror stays observation-only |
| 2025-06 | Research report chose Appium path — superseded by packaged mobile-mcp pilot |
