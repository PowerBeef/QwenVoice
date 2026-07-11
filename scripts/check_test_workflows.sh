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
  scripts/frontend_status_capture.sh \
  scripts/perf_investigation.sh \
  scripts/build_and_run.sh \
  Sources/iOS/IOSPreviewSupport.swift \
  Sources/iOS/IOSAutorunHarness.swift \
  benchmarks/macos-frontend-status-audit-2026-06-29.md \
  benchmarks/perf-investigation-2026-06-29.md \
  benchmarks/benchmarking-procedure-audit-2026-06-29.md \
  docs/reference/telemetry-harness-review.md \
  docs/superpowers/plans/2026-06-16-telemetry-phase-4.md \
  Tests/DeviceProbeFixtures/text-call-active.txt \
  Tests/DeviceProbeFixtures/text-mirror-active.txt \
  Tests/DeviceProbeFixtures/text-mirror-connecting.txt \
  Tests/DeviceProbeFixtures/text-phone-in-use.txt; do
  [[ ! -e "$retired" ]] || fail "retired UI harness artifact still exists: $retired"
done

active=(AGENTS.md README.md .gitignore .agents benchmarks docs scripts config .github project.yml QwenVoice.xcodeproj/project.pbxproj Sources Tests website QwenVoice_MLXAudio_Corrected_Report_Series_2026-07-10)
excludes=(
  --glob '!scripts/check_test_workflows.sh'
  --glob '!scripts/clean_build_caches.sh'
)

# Match the retired IDE by its development-context terms, not the generic UI/CSS
# concept of a cursor or insertion caret.
retired_pattern='(?i:cursor[- ]era|cursor IDE|cursor agent|cursor/claude|\.cursor(?:/|\b)|~/\.cursor|computer[-‑ ]use|mirroir|peekaboo|mobile-mcp|macos_agent_ui|ios_agent_ui|computer_use_routing|vocello-(?:macos|ios)-ui-qa|computer-use-failure-analysis|ui-attestation|ui-test-surface|generate_ui_test_surface|ios_agent_bench_drive|ios_vision_bridge|ios_measure|ios_uitest_doctor|enable_unattended_uitest|xcresult_shots|ios_vision_bench_matrix|ios_test_models|IOSModelsInventoryWriter|IOSAutorunHarness|IOSPreviewSupport|frontend_status_capture|perf_investigation|build_and_run)'
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

hidden_hook_pattern='HiddenAccessibilityMarker|QWENVOICE_UI_TEST_HOOKS|QWENVOICE_FAKE_MIC_WAV|QVOICE_IOS_SKIP_ONBOARDING|QVOICE_IOS_TEST_CUSTOM_TEXT|screenPresenceMarker|MacUITestSurfaceMarkers|IOSStudioBenchHooks|IOSPreviewRuntime|IOSPreviewCaptureBridge|QVOICE_PREVIEW_|mainWindow_(?:ready|activeScreen|disabledSidebarItems|lastGenerationComplete|lastTelemetryFlushed|composeReady)|iosStudio_(?:lastGenerationComplete|generationError|benchClearScript)'
out="$(rg -n "$hidden_hook_pattern" Sources Tests scripts docs project.yml \
  --glob '!scripts/check_test_workflows.sh' 2>/dev/null || true)"
[[ -z "$out" ]] || fail "hidden UI-test marker/hook returned; assert real visible state instead:\n$out"

# There is one shippable Release configuration and no generic DEBUG symbol.
# Runtime diagnostics use DebugMode/TelemetryGate; named QVOICE_* feature
# conditions remain valid when a behavior truly must be selected at compile time.
out="$(rg -n --pcre2 '^[\t ]*#(?:if|elseif)\b[^\n]*\bDEBUG\b' Sources \
  --glob '*.swift' 2>/dev/null || true)"
[[ -z "$out" ]] || fail "generic #if DEBUG branch returned in shippable Sources:\n$out"

# Detect structural one-point accessibility anchors even when their type/name is
# changed. Identifiers belong on the genuine visible control or state container.
python3 - <<'PY'
from pathlib import Path

errors = []
for path in Path("Sources").rglob("*.swift"):
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if ".frame(width: 1, height: 1" not in line.replace("1.0", "1"):
            continue
        start = max(0, index - 10)
        end = min(len(lines), index + 11)
        region = "\n".join(lines[start:end])
        if ".opacity(0.01)" in region and ".accessibilityIdentifier(" in region:
            errors.append(f"{path}:{index + 1}: invisible one-point accessibility marker")
if errors:
    raise SystemExit("\n".join(errors))
PY

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

# The macOS runner may signal only PIDs whose executable resolves to its exact
# DerivedData product. A name-wide kill could terminate a user's other Vocello.
rg -q 'process_executable_path' scripts/ui_test.sh \
  || fail "macOS UI runner lost exact executable identity validation"
rg -q 'Build/Products/Release/Vocello\.app/Contents/MacOS/Vocello' scripts/ui_test.sh \
  || fail "macOS UI runner lost its exact test-host executable path"
out="$(rg -n 'pkill[^\n]*(?:Vocello|QwenVoiceEngineService)' scripts/ui_test.sh 2>/dev/null || true)"
[[ -z "$out" ]] || fail "macOS UI runner must never name-kill Vocello processes:\n$out"

# The only app-UI topology is two isolated schemes and two UI-test bundles.
python3 - <<'PY'
from pathlib import Path
import re

text = Path("project.yml").read_text(encoding="utf-8")
for name in ("VocelloMacUI", "VocelloiOSUI", "VocelloMacUITests", "VocelloiOSUITests"):
    count = len(re.findall(rf"^  {re.escape(name)}:$", text, re.MULTILINE))
    if count != 1:
        raise SystemExit(f"project.yml must define {name} exactly once (found {count})")
for target, host in (("VocelloMacUITests", "QwenVoice"), ("VocelloiOSUITests", "VocelloiOS")):
    match = re.search(rf"^  {target}:\n(?P<body>(?:    .*\n|\n)*)", text, re.MULTILINE)
    body = match.group("body") if match else ""
    if "type: bundle.ui-testing" not in body or f"TEST_TARGET_NAME: {host}" not in body:
        raise SystemExit(f"{target} must remain an isolated UI-test bundle hosted by {host}")
for scheme in ("QwenVoice", "VocelloiOS"):
    match = re.search(rf"^  {scheme}:\n(?P<body>(?:    .*\n|\n)*)", text, re.MULTILINE)
    if match is None:
        raise SystemExit(f"project.yml is missing ordinary scheme {scheme}")
    body = match.group("body")
    if "VocelloMacUITests" in body or "VocelloiOSUITests" in body:
        raise SystemExit(f"ordinary scheme {scheme} must not include a UI-test bundle")
PY

# Ordinary CI must neither compile UI-test bundles nor execute UI acceptance.
ci_error="$(python3 - <<'PY'
from pathlib import Path
import re

paths = (Path('.github/workflows/ci.yml'), Path('.github/workflows/release.yml'))
patterns = {
    r'\btest-without-building\b': 'executes XCUITest',
    r'\bscripts/ui_test\.sh\b': 'invokes an app UI lane',
    r'\bxcodebuild\s+test\b': 'executes xcodebuild test',
    r'\b(?:VocelloMacUI|VocelloiOSUI|VocelloMacUITests|VocelloiOSUITests)\b': 'references an isolated UI-test scheme or bundle',
}
for path in paths:
    text = path.read_text(encoding='utf-8')
    for pattern, label in patterns.items():
        if re.search(pattern, text):
            raise SystemExit(f'{path} {label}; UI execution must stay explicit')
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

# Validate local HTML links in the active project map as well as Markdown links.
python3 - <<'PY'
from pathlib import Path
import re

errors = []
for source in Path("docs").rglob("*.html"):
    text = source.read_text(encoding="utf-8")
    for target in re.findall(r'(?:href|src)=["\']([^"\']+)["\']', text):
        if not target or target.startswith(("#", "http://", "https://", "data:", "mailto:")):
            continue
        path_part = target.split("#", 1)[0].split("?", 1)[0]
        if path_part and not (source.parent / path_part).resolve().exists():
            errors.append(f"{source}: missing HTML target {target}")
if errors:
    raise SystemExit("\n".join(errors))
PY

# Literal documented script commands must resolve to real dispatch forms. This
# deliberately checks active guidance, while immutable release notes stay history.
python3 - <<'PY'
from pathlib import Path
import re

roots = [Path("AGENTS.md"), Path("README.md"), Path(".agents"), Path("docs/reference")]
files = []
for root in roots:
    files.extend([root] if root.is_file() else root.rglob("*.md"))
allowed = {
    "ios_device.sh": {"doctor", "build", "install", "launch", "console", "pull", "bench", "lang-bench", "crashes", "debug", "logs", "profile", "preflight", "device-state", "gate", "help"},
    "macos_test.sh": {"preflight", "core-test", "lang-bench", "test", "telemetry-overhead", "crashes", "debug", "logs", "profile", "gate", "release-readiness", "models", "help"},
}
errors = []
command = re.compile(r"(?:\./)?scripts/(ios_device\.sh|macos_test\.sh)\s+([a-z][a-z0-9-]*)")
baseline = re.compile(r"--compare-baseline(?:=|\s+)([^\s`\\]+)")
for path in files:
    text = path.read_text(encoding="utf-8")
    for script, subcommand in command.findall(text):
        if subcommand not in allowed[script]:
            errors.append(f"{path}: unsupported {script} command: {subcommand}")
    for argument in baseline.findall(text):
        if argument.startswith(("$", "<")):
            continue
        if Path(argument.strip('"\'')).suffix.lower() != ".json":
            errors.append(f"{path}: --compare-baseline requires a JSON baseline, not {argument}")
if errors:
    raise SystemExit("\n".join(errors))
PY

# Catch stale inline source/test/script paths in active guidance. Vendored MLX
# sources may be documented relative to their package root.
python3 - <<'PY'
from pathlib import Path
import glob
import re

roots = [Path("AGENTS.md"), Path("README.md"), Path(".agents"), Path("docs/reference")]
files = []
for root in roots:
    files.extend([root] if root.is_file() else root.rglob("*.md"))
prefixes = ("Sources/", "Tests/", "scripts/", "config/", ".github/")
errors = []
for source in files:
    text = source.read_text(encoding="utf-8")
    for value in re.findall(r"`([^`\n]+)`", text):
        candidate = value.strip().split()[0].rstrip(".,;:")
        candidate = re.sub(r":\d+(?:-\d+)?$", "", candidate)
        if not candidate.startswith(prefixes) or not Path(candidate).suffix:
            continue
        if any(marker in candidate for marker in ("<", ">", "{", "}", "$")):
            continue
        matches = glob.glob(candidate) if "*" in candidate else ([candidate] if Path(candidate).exists() else [])
        if not matches and candidate.startswith("Sources/"):
            vendored = Path("third_party_patches/mlx-audio-swift") / candidate
            matches = [str(vendored)] if vendored.exists() else []
        if not matches:
            errors.append(f"{source}: stale inline path {candidate}")
if errors:
    raise SystemExit("\n".join(errors))
PY

# Tracked artifacts must not capture a developer's absolute home path. The
# explicit /Users/example privacy-test fixture is intentionally synthetic.
out="$(git grep -nE '/Users/[A-Za-z0-9._-]+/' -- ':!scripts/check_test_workflows.sh' 2>/dev/null \
  | rg -v '/Users/example/' || true)"
[[ -z "$out" ]] || fail "tracked developer home path returned; use a relative or redacted path:\n$out"

python3 scripts/validate_backend_risk_spine.py

python3 -m unittest \
  scripts.test_check_macos_xpc_bench \
  scripts.test_check_ios_ui_benchmark \
  scripts.test_device_state_classifier \
  scripts.test_validate_backend_risk_spine

echo "==> XCUITest workflow consistency check passed" >&2
