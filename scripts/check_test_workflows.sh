#!/usr/bin/env bash
# Keep the repository on one app-UI automation stack: XCUITest.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { printf '\033[0;31m[test-workflow]\033[0m %s\n' "$*" >&2; exit 1; }
command -v rg >/dev/null 2>&1 || fail "ripgrep is required"

echo "==> XCUITest workflow consistency check" >&2

for required in \
  Tests/UIAutomationSupport \
  Tests/VocelloMacUITests \
  Tests/VocelloiOSUITests; do
  [[ -d "$required" ]] || fail "required XCUITest source directory is missing: $required"
done

for retired in \
  .cursor \
  .mirroir-mcp \
  .agents/skills/vocello-macos-ui-qa \
  .agents/skills/vocello-ios-ui-qa \
  scripts/macos_agent_ui.sh \
  scripts/ios_agent_ui.sh \
  scripts/lib/macos_agent_ui.py \
  scripts/lib/ios_agent_ui.py \
  scripts/lib/computer_use_routing.py \
  scripts/test_macos_agent_ui.py \
  scripts/test_computer_use_routing.py \
  config/macos-ui-scenarios.json \
  config/ios-ui-scenarios.json \
  config/macos-test-impact.json \
  config/ios-test-impact.json \
  qa/macos-ui-attestation.json \
  qa/ios-ui-attestation.json \
  docs/reference/computer-use-failure-analysis.md \
  docs/reference/ui-smoke-runbooks.md \
  docs/reference/ios-device-probe.md \
  benchmarks/macos-multi-mode-ui-xpc-audit-2026-06-29.md \
  docs/macos-review-baselines \
  docs/ios-review-baselines \
  scripts/install_mirroir_user_config.sh \
  scripts/ios_mirroir_preflight.sh \
  scripts/ios_mobile_mcp.sh \
  scripts/lib/ios_mirror_discovery.sh \
  scripts/lib/ios_agent_bench_drive.sh \
  scripts/lib/ios_vision_bridge.sh \
  scripts/lib/ios_measure.sh \
  Tests/DeviceProbeFixtures/text-call-active.txt \
  Tests/DeviceProbeFixtures/text-mirror-active.txt \
  Tests/DeviceProbeFixtures/text-mirror-connecting.txt \
  Tests/DeviceProbeFixtures/text-phone-in-use.txt; do
  [[ ! -e "$retired" ]] || fail "retired UI harness artifact still exists: $retired"
done

active=(AGENTS.md README.md .gitignore .agents benchmarks docs scripts config .github project.yml Sources Tests website/AGENTS.md)
excludes=(
  --glob '!scripts/check_test_workflows.sh'
  --glob '!docs/releases/**'
  --glob '!website/**'
)

retired_pattern='\bCursor\b|\.cursor|(?i:computer[-‑ ]use|mirroir|peekaboo|mobile-mcp|macos_agent_ui|ios_agent_ui|computer_use_routing|vocello-(?:macos|ios)-ui-qa|computer-use-failure-analysis|ui-attestation|ui-test-surface|generate_ui_test_surface|ios_agent_bench_drive|ios_vision_bridge|ios_measure|ios_uitest_doctor|enable_unattended_uitest|xcresult_shots|ios_vision_bench_matrix|ios_test_models|IOSModelsInventoryWriter)'
out="$(rg -n "$retired_pattern" "${active[@]}" "${excludes[@]}" 2>/dev/null || true)"
[[ -z "$out" ]] || fail "retired development or UI harness content returned:\n$out"

# Reject only retired command/dispatch forms. Generic UI-test prose, code review, and Xcode's
# bundle.ui-testing target type are valid and intentionally do not match these expressions.
retired_alias_pattern='(?x)(?:
  (?<![[:alnum:]_-])bench-ui(?![[:alnum:]_-])
  | (?<![[:alnum:]_-])ui-report(?![[:alnum:]_-])
  | (?:^|[[:space:]`])(?:(?:\./)?scripts/)?(?:macos_test|ios_device)\.sh[[:space:]]+(?:ui-test|review)\b
  | ^[[:space:]]*(?:ui-test|review)\)
  | --suite(?:=|[[:space:]]+)(?:quick|full|benchmark)\b
)'
out="$(rg -n --pcre2 "$retired_alias_pattern" "${active[@]}" "${excludes[@]}" 2>/dev/null || true)"
[[ -z "$out" ]] || fail "retired UI command or suite alias returned:\n$out"

# UI acceptance is explicit and independent; packaging/readiness may not reacquire a UI-result gate.
release_ui_gate_pattern='(?i:gated by fresh (?:macOS|iOS|frontend|UI)|requires fresh .*XCUITest|XCUITest .* prerequisite.*(?:release|packag|archive)|(?:release|packag|archive).*(?:requires|required).*XCUITest)'
out="$(rg -n --pcre2 "$release_ui_gate_pattern" AGENTS.md README.md .agents docs scripts .github \
  "${excludes[@]}" 2>/dev/null || true)"
[[ -z "$out" ]] || fail "release packaging must remain independent of XCUITest evidence:\n$out"

hidden_hook_pattern='HiddenAccessibilityMarker|QWENVOICE_UI_TEST_HOOKS|QWENVOICE_FAKE_MIC_WAV|QVOICE_IOS_SKIP_ONBOARDING|QVOICE_IOS_TEST_CUSTOM_TEXT|screenPresenceMarker|MacUITestSurfaceMarkers|IOSStudioBenchHooks|mainWindow_(?:ready|activeScreen|disabledSidebarItems|lastGenerationComplete|lastTelemetryFlushed|composeReady)|iosStudio_(?:lastGenerationComplete|generationError|benchClearScript)'
out="$(rg -n "$hidden_hook_pattern" Sources Tests scripts docs project.yml \
  --glob '!scripts/check_test_workflows.sh' 2>/dev/null || true)"
[[ -z "$out" ]] || fail "hidden UI-test marker/hook returned; assert real visible state instead:\n$out"

python3 - <<'PY'
from pathlib import Path

text = Path("scripts/lib/test_models.sh").read_text(encoding="utf-8")
approved_clone_sha256 = "03187893a3d82d38264d433f24828982c67ed42cddb71eefccb776b37ab9fe35"
required = (
    'MAC_TEST_CLONE_VOICE_BRIEF=',
    'MAC_TEST_CLONE_REF_TRANSCRIPT=',
    f'MAC_TEST_CLONE_REF_SHA256="{approved_clone_sha256}"',
    'generate --mode design --variant speed',
    '--voice-brief "$MAC_TEST_CLONE_VOICE_BRIEF"',
    'mac_test_clone_fixture_current',
    'shasum -a 256 "$audio_file"',
    '"$actual_sha256" == "$MAC_TEST_CLONE_REF_SHA256"',
)
missing = [token for token in required if token not in text]
if missing:
    raise SystemExit(f"clone benchmark fixture lost Voice Design provenance: {missing}")
if 'generate --mode custom --variant speed' in text:
    raise SystemExit("clone benchmark fixture must not be synthesized from the default Custom speaker")
PY

out="$(rg -n '\b(?:sleep|usleep)\s*\(|Thread\.sleep|coordinate\s*\(' \
  Tests/UIAutomationSupport Tests/VocelloMacUITests Tests/VocelloiOSUITests 2>/dev/null || true)"
[[ -z "$out" ]] || fail "UI tests must use condition waits and exact elements, not delays/coordinates:\n$out"

out="$(rg -n 'matching\s*\(\s*NSPredicate\s*\(\s*format:\s*"label|buttons\s*\[\s*"(?:Generate|Custom|Design|Clone|Dismiss)' \
  Tests/UIAutomationSupport Tests/VocelloMacUITests Tests/VocelloiOSUITests 2>/dev/null || true)"
[[ -z "$out" ]] || fail "UI tests must use stable accessibility identifiers, not visible-label fallbacks:\n$out"

for token in 'VocelloMacUI:' 'VocelloiOSUI:' 'VocelloMacUITests:' 'VocelloiOSUITests:'; do
  rg -q "^[[:space:]]*${token}" project.yml || fail "project.yml is missing $token"
done

# Ordinary CI must neither compile UI-test bundles nor execute UI acceptance.
ci_error="$(python3 - <<'PY'
from pathlib import Path
import re

path = Path('.github/workflows/ci.yml')
text = path.read_text(encoding='utf-8')
patterns = {
    r'\btest-without-building\b': 'executes XCUITest',
    r'\bscripts/ui_test\.sh\b': 'invokes an app UI lane',
    r'\bxcodebuild\s+test\b': 'executes xcodebuild test',
    r'\b(?:VocelloMacUI|VocelloiOSUI|VocelloMacUITests|VocelloiOSUITests)\b': 'references an isolated UI-test scheme or bundle',
}
for pattern, label in patterns.items():
    if re.search(pattern, text):
        raise SystemExit(f'ordinary CI {label}; UI execution must stay explicit')
PY
2>&1 || true)"
[[ -z "$ci_error" ]] || fail "$ci_error"

# No simulator destination is supported for Vocello app UI automation.
out="$(rg -n -i 'platform=iOS Simulator|build_run_sim|test_sim|launch_sim' \
  AGENTS.md README.md .agents docs scripts project.yml .github \
  --glob '!scripts/check_test_workflows.sh' 2>/dev/null || true)"
[[ -z "$out" ]] || fail "active Simulator workflow returned:\n$out"

# Validate relative Markdown links so deleted harness documents cannot remain referenced.
python3 - <<'PY'
from pathlib import Path
import re

roots = [Path('AGENTS.md'), Path('README.md'), Path('.agents'), Path('benchmarks'), Path('docs')]
files = []
for root in roots:
    if root.is_file():
        files.append(root)
    elif root.is_dir():
        files.extend(root.rglob('*.md'))

errors = []
pattern = re.compile(r'\[[^\]]*\]\(([^)]+)\)')
for source in files:
    text = source.read_text(encoding='utf-8')
    for target in pattern.findall(text):
        target = target.strip().strip('<>')
        if not target or target.startswith(('#', 'http://', 'https://', 'mailto:', 'plugin://')):
            continue
        path_part = target.split('#', 1)[0]
        if not path_part:
            continue
        resolved = (source.parent / path_part).resolve()
        if not resolved.exists():
            errors.append(f'{source}: missing link target {target}')
if errors:
    raise SystemExit('\n'.join(errors))
PY

python3 -m unittest \
  scripts.test_check_macos_xpc_bench \
  scripts.test_check_ios_ui_benchmark \
  scripts.test_device_state_classifier

echo "==> XCUITest workflow consistency check passed" >&2
