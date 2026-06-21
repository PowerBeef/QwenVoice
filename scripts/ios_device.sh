#!/usr/bin/env bash
# Headless iPhone build/test driver for Vocello — the on-device analog of
# `vocello bench`. Drives a real device over Apple's `devicectl` (CoreDevice): no
# screen mirroring, no UI scripting. This replaced the earlier iPhone-Mirroring
# UI-driving method.
#
# Pairs with IOSAutorunHarness (Sources/iOS/IOSAutorunHarness.swift): `bench`
# launches the app with QVOICE_IOS_AUTORUN set, the in-app harness runs one
# generation with no UI and writes a completion sentinel + telemetry into the
# App-Group container, and this script pulls them back and summarizes.
#
# Privacy: the signing team is DERIVED AT RUNTIME from the local keychain (the OU of
# the "Apple Development" cert) — never hardcoded/committed; $QWENVOICE_DEVELOPMENT_TEAM
# overrides. The device is auto-discovered, or pinned via $QVOICE_IOS_DEVICE_ID —
# neither is committed. Signing uses automatic provisioning by default and falls back
# to OFFLINE manual signing (the already-installed dev profile + the Apple Development
# identity) when no Apple ID is signed into Xcode — so no account login is needed.
#
# Usage:
#   scripts/ios_device.sh doctor                  # environment + device preflight
#   scripts/ios_device.sh build                   # signed device build (-Onone)
#   scripts/ios_device.sh install                 # install the built app
#   scripts/ios_device.sh launch [spec]           # launch (with autorun if spec given)
#   scripts/ios_device.sh console [spec]          # attached launch, stream [autorun] stdout live
#   scripts/ios_device.sh mirror                  # start iPhone Mirroring + confirm device reachable
#   scripts/ios_device.sh shot [out.png]          # capture the iPhone Mirroring window (device screen) → PNG
#   scripts/ios_device.sh pull [dest]             # pull the app-container diagnostics mirror
#   scripts/ios_device.sh bench [spec] [--label "note"]
#                                                 # build→install→autorun→pull→summarize
#   scripts/ios_device.sh ui-test [only]          # run VocelloiOSUITests ON THE DEVICE (signed XCUITest)
#
# Observation: every device command auto-starts macOS iPhone Mirroring (watch on the Mac;
# the phone stays locked + screen-dark, OLED-safe; mirroring also keeps a LOCKED device
# reachable to devicectl). Opt out with QVOICE_IOS_NO_MIRROR=1. Lock the phone once per
# session (Apple has no Mac-side lock CLI) or rely on Auto-Lock.
#
# Autorun spec: <mode>:<variant>:<text> (default custom:speed:<built-in sentence>).
#   mode ∈ custom|design|clone, variant ∈ speed|quality (iPhone is speed-only).
#
# Env:
#   QWENVOICE_DEVELOPMENT_TEAM   (optional) Apple team id; auto-derived from the keychain
#                                Apple Development cert OU when unset
#   QVOICE_IOS_MANUAL_SIGN       (optional) set to 1 to force offline manual signing
#                                (otherwise automatic, with auto-fallback to manual)
#   QVOICE_IOS_DEVICE_ID         (optional) devicectl device id/name/udid; else auto
#   QVOICE_IOS_BENCH_TIMEOUT     (optional) bench sentinel timeout seconds (default 300)
#   QVOICE_IOS_NO_MIRROR         (optional) set to 1 to skip auto-starting iPhone Mirroring

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="VocelloiOS"
CONFIG="Release"
BUNDLE_ID="com.patricedery.vocello"
APP_GROUP="group.com.patricedery.vocello.shared"
# Single shared iOS DerivedData tree: device (iphoneos) + simulator (build-for-testing)
# builds coexist here with one SourcePackages, so iOS build trees don't multiply.
# Swept/reclaimed by scripts/clean_build_caches.sh (--aggressive) + build.sh's prune.
DERIVED="$ROOT_DIR/build/ios"
APP_PATH="$DERIVED/Build/Products/Release-iphoneos/Vocello.app"
PROJECT="$ROOT_DIR/QwenVoice.xcodeproj"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

# Reuse the shared storage-bloat advisory (warn-only; never deletes).
. "$ROOT_DIR/scripts/lib/build_cache.sh"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

MIRROR_APP="iPhone Mirroring"   # bundle com.apple.ScreenContinuity

# Auto-start macOS iPhone Mirroring for OBSERVATION before on-device work: the phone stays
# locked + screen-dark (OLED-safe) and you watch live on the Mac. KEY: iPhone Mirroring
# sustains the CoreDevice tunnel, so a LOCKED device stays `devicectl`-reachable (a
# locked phone WITHOUT mirroring drops to "unavailable"). Idempotent + fast when already up.
# Opt out with QVOICE_IOS_NO_MIRROR=1. (Locking the phone itself is an Apple security
# boundary — no Mac-side CLI does it — so lock once per session, it then stays locked while
# mirroring, or rely on the phone's Auto-Lock; iPhone Mirroring reconnects on auto-lock.)
ensure_mirror() {
  [[ "${QVOICE_IOS_NO_MIRROR:-}" == "1" ]] && return 0
  if pgrep -fq "iPhone Mirroring" 2>/dev/null \
     && xcrun devicectl list devices 2>/dev/null | grep -qi "available"; then
    return 0   # already mirroring and a device is reachable
  fi
  note "starting iPhone Mirroring (observation; keeps a locked device reachable, OLED-safe)…"
  open -a "$MIRROR_APP" >/dev/null 2>&1 || warn "could not launch iPhone Mirroring ($MIRROR_APP)"
  local waited=0
  while (( waited < 30 )); do
    if xcrun devicectl list devices 2>/dev/null | grep -qi "available"; then
      note "iPhone Mirroring up; device reachable."
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  warn "device not 'available' yet — LOCK your iPhone (or wait for Auto-Lock) so iPhone Mirroring connects, then re-run."
}

# mirror: start/foreground iPhone Mirroring + confirm the device is reachable (manual use).
cmd_mirror() { ensure_mirror; }

# shot [out.png]: capture the iPhone Mirroring window (the live device screen) to a PNG — the
# device analog of `ios_sim.sh shot`, for visual UI review on REAL hardware. devicectl has no
# screenshot and this Mac has no libimobiledevice, so we screencapture the Mirroring window region.
# NOT pixel-exact (includes the Mirroring chrome / device bezel at window scale) — it's for judging
# layout / color / spacing. We CAPTURE only; navigating across screens is done by tapping the phone
# (coordinate-based mirror-DRIVING stays deprecated). First run may prompt for Screen Recording +
# Automation permission for the controlling terminal (System Settings → Privacy & Security).
cmd_shot() {
  local out="${1:-$ROOT_DIR/build/device-shot.png}"
  command -v screencapture >/dev/null 2>&1 || die "screencapture not found (macOS only)"
  mkdir -p "$(dirname "$out")"

  # Bring Mirroring frontmost so the captured region isn't occluded by another window.
  open -a "$MIRROR_APP" >/dev/null 2>&1 || true
  osascript -e "tell application \"$MIRROR_APP\" to activate" >/dev/null 2>&1 || true
  sleep 0.6

  # Read the Mirroring window's screen rect (points, top-left origin — same space screencapture -R uses).
  local rect
  rect="$(osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
  if not (exists process "iPhone Mirroring") then return ""
  tell process "iPhone Mirroring"
    if (count of windows) is 0 then return ""
    set p to position of window 1
    set s to size of window 1
    -- Coerce each number to text BEFORE concatenating; `integer & ","` builds a list, not a string.
    set x to ((item 1 of p) as integer) as text
    set y to ((item 2 of p) as integer) as text
    set w to ((item 1 of s) as integer) as text
    set h to ((item 2 of s) as integer) as text
    return x & "," & y & "," & w & "," & h
  end tell
end tell
OSA
)"

  [[ -n "$rect" ]] || die "couldn't read the iPhone Mirroring window — open + connect it first ('$0 mirror', showing the device), and grant Automation permission if prompted"

  note "capturing iPhone Mirroring window [$rect] → $out"
  screencapture -x -R "$rect" "$out" \
    || die "screencapture failed — grant Screen Recording permission to this terminal (System Settings → Privacy & Security → Screen Recording), then retry"
  [[ -s "$out" ]] || die "screencapture produced an empty file — check Screen Recording permission"
  printf '%s\n' "$out"
}

# ─── Code signing (all values DERIVED AT RUNTIME; never hardcoded/committed) ──────
# Team id = the OU of the keychain "Apple Development" cert. NOTE: the team is the
# cert's OU, NOT the parenthetical in its CN ("Apple Development: …(XXXXXXXXXX)") —
# that parenthetical is a per-developer identifier; mistaking it for the team yields
# "No Account for Team …". $QWENVOICE_DEVELOPMENT_TEAM overrides if set.
derive_team() {
  if [[ -n "${QWENVOICE_DEVELOPMENT_TEAM:-}" ]]; then
    printf '%s' "$QWENVOICE_DEVELOPMENT_TEAM"; return 0
  fi
  local t
  t="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -oE 'OU=[A-Z0-9]+' | head -1 | cut -d= -f2)"
  [[ -n "$t" ]] || return 1
  export QWENVOICE_DEVELOPMENT_TEAM="$t"
  printf '%s' "$t"
}

require_team() {
  derive_team >/dev/null \
    || die "no signing team — set QWENVOICE_DEVELOPMENT_TEAM=<apple-team-id>, or install an 'Apple Development' certificate (Xcode → Settings → Accounts) so it can be auto-derived from the keychain"
}

# Echo the NAME of the installed *development* provisioning profile (get-task-allow=true)
# whose application-identifier == <team>.<BUNDLE_ID>. Empty if none. Lets manual signing
# reuse an already-present profile with zero Apple-account round-trip.
find_dev_profile_name() {
  local team="$1"
  [[ -d "$PROFILES_DIR" ]] || return 0
  local f plist appid gta name
  for f in "$PROFILES_DIR"/*.mobileprovision; do
    [[ -e "$f" ]] || continue
    plist="$(security cms -D -i "$f" 2>/dev/null)" || continue
    gta="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' /dev/stdin <<<"$plist" 2>/dev/null)"
    [[ "$gta" == "true" ]] || continue
    appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' /dev/stdin <<<"$plist" 2>/dev/null)"
    if [[ "$appid" == "$team.$BUNDLE_ID" ]]; then
      name="$(/usr/libexec/PlistBuddy -c 'Print :Name' /dev/stdin <<<"$plist" 2>/dev/null)"
      [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
    fi
  done
  return 0
}

# Populate SIGN_ARGS for xcodebuild. auto = automatic signing + provisioning updates
# (needs the Apple ID present in Xcode). manual = the installed dev profile + the
# Apple Development identity, fully offline (no Apple-account contact).
SIGN_ARGS=()
build_sign_args() {
  local mode="$1" team="$2"
  if [[ "$mode" == manual ]]; then
    local prof; prof="$(find_dev_profile_name "$team")"
    [[ -n "$prof" ]] || die "manual signing: no installed development profile for $team.$BUNDLE_ID (generate one once via Xcode, or unset QVOICE_IOS_MANUAL_SIGN to use automatic signing)"
    note "manual signing → profile: $prof"
    SIGN_ARGS=(
      DEVELOPMENT_TEAM="$team"
      CODE_SIGN_STYLE=Manual
      PROVISIONING_PROFILE_SPECIFIER="$prof"
      CODE_SIGN_IDENTITY="Apple Development"
    )
  else
    SIGN_ARGS=(
      -allowProvisioningUpdates
      DEVELOPMENT_TEAM="$team"
      CODE_SIGN_STYLE=Automatic
    )
  fi
}

# Resolve the target device id. Prefer $QVOICE_IOS_DEVICE_ID; otherwise auto-pick the
# single connected/paired CoreDevice. Errors with the device list when ambiguous.
resolve_device() {
  if [[ -n "${QVOICE_IOS_DEVICE_ID:-}" ]]; then
    printf '%s' "$QVOICE_IOS_DEVICE_ID"
    return
  fi
  local tmp; tmp="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1 \
    || die "devicectl could not list devices (is Xcode 26 installed?)"
  local id
  id="$(python3 - "$tmp" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
devs = (data.get("result") or {}).get("devices") or []
def connected(d):
    cp = d.get("connectionProperties") or {}
    return cp.get("pairingState") == "paired" or cp.get("tunnelState") in ("connected", "available")
cands = [d for d in devs if connected(d)]
if len(cands) == 1:
    print(cands[0].get("identifier", ""))
elif not cands:
    sys.exit(3)
else:
    for d in cands:
        props = d.get("deviceProperties") or {}
        sys.stderr.write(f"  {d.get('identifier')}  {props.get('name','?')}\n")
    sys.exit(4)
PY
)" || {
    local code=$?
    rm -f "$tmp"
    [[ $code -eq 3 ]] && die "no paired iPhone found — connect via USB + trust this Mac, or set QVOICE_IOS_DEVICE_ID"
    [[ $code -eq 4 ]] && die "multiple devices found (above) — set QVOICE_IOS_DEVICE_ID to one"
    die "device discovery failed"
  }
  rm -f "$tmp"
  [[ -n "$id" ]] || die "could not resolve a device id"
  printf '%s' "$id"
}

cmd_doctor() {
  note "Vocello iOS device doctor"
  command -v xcrun >/dev/null || die "xcrun not found (install Xcode)"
  printf '  xcode: %s\n' "$(xcodebuild -version 2>/dev/null | head -1)" >&2
  local team_d
  if team_d="$(derive_team 2>/dev/null)" && [[ -n "$team_d" ]]; then
    local src="keychain"; [[ -n "${QWENVOICE_DEVELOPMENT_TEAM:-}" ]] && src="env"
    printf '  team:  %s (%s)\n' "$team_d" "$src" >&2
  else
    warn "no signing team — set QWENVOICE_DEVELOPMENT_TEAM, or add an Apple Development cert (Xcode → Settings → Accounts)"
  fi
  local dev; dev="$(resolve_device)"
  printf '  device: %s\n' "$dev" >&2
  if [[ -d "$APP_PATH" ]]; then
    printf '  app:   built (%s)\n' "$APP_PATH" >&2
    printf '  entitlement: ' >&2
    codesign -d --entitlements :- "$APP_PATH" 2>/dev/null \
      | grep -o 'increased-memory-limit' | head -1 || printf '(not found)\n' >&2
    printf '\n' >&2
  else
    printf '  app:   not built yet (run: %s build)\n' "$0" >&2
  fi
  note "doctor OK"
}

cmd_build() {
  require_team
  local team; team="$(derive_team)"
  local dev; dev="$(resolve_device)"
  note "building $SCHEME ($CONFIG, -Onone) for $dev (team $team)"
  mkdir -p "$DERIVED"
  local log="$DERIVED/device-build.log"

  local mode="auto"
  [[ "${QVOICE_IOS_MANUAL_SIGN:-}" == "1" ]] && mode="manual"

  _run_device_build() {
    build_sign_args "$1" "$team"
    set +e
    xcodebuild \
      -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination "id=$dev" -derivedDataPath "$DERIVED" \
      "${SIGN_ARGS[@]}" \
      SWIFT_OPTIMIZATION_LEVEL=-Onone \
      build 2>&1 | tee "$log"
    local st=${PIPESTATUS[0]}; set -e; return $st
  }

  if _run_device_build "$mode"; then
    :
  elif [[ "$mode" == auto ]] \
       && grep -qiE "No Account for Team|requires a development team|No profiles for|No signing certificate|Provisioning profile" "$log"; then
    warn "automatic signing failed (Apple ID likely not signed into Xcode) — retrying offline with the installed development profile"
    _run_device_build manual || die "manual-signing build also failed (see $log)"
  else
    die "device build failed (see $log)"
  fi

  [[ -d "$APP_PATH" ]] || die "build finished but $APP_PATH is missing"
  note "built $APP_PATH"
  warn_if_storage_bloated
}

cmd_install() {
  [[ -d "$APP_PATH" ]] || die "no built app at $APP_PATH (run: $0 build)"
  local dev; dev="$(resolve_device)"
  note "installing on $dev"
  xcrun devicectl device install app --device "$dev" "$APP_PATH"
}

# launch [spec]: with a spec, set the autorun + telemetry env; without, a plain launch.
cmd_launch() {
  local spec="${1:-}"
  local dev; dev="$(resolve_device)"
  if [[ -n "$spec" ]]; then
    local run_id="ios-$(date +%Y%m%d-%H%M%S)"
    note "launching with autorun ($spec), runID=$run_id"
    local env_json
    # Benchmark A/B passthrough: any caller-set QWENVOICE_*/QVOICE_* tuning env
    # (e.g. QWENVOICE_STREAMING_PREVIEW_DATA=off, QWENVOICE_FORCE_MEMORY_CLASS)
    # is forwarded into the launched app's env so on-device benches are reproducible.
    env_json="$(QV_SPEC="$spec" QV_RUNID="$run_id" python3 -c '
import json, os
env = {
    "QWENVOICE_DEBUG": "1",
    "QVOICE_IOS_DEVICE_RUN_ID": os.environ["QV_RUNID"],
    "QVOICE_IOS_AUTORUN": os.environ["QV_SPEC"],
}
for k, v in os.environ.items():
    if (k.startswith("QWENVOICE_") or k.startswith("QVOICE_")) and k not in env:
        env[k] = v
print(json.dumps(env))')"
    xcrun devicectl device process launch --device "$dev" \
      --terminate-existing -e "$env_json" "$BUNDLE_ID" >&2
    printf '%s\n' "$run_id"   # stdout: ONLY the runID (consumed by bench)
  else
    note "launching $BUNDLE_ID"
    xcrun devicectl device process launch --device "$dev" --terminate-existing "$BUNDLE_ID"
  fi
}

# console [spec]: launch ATTACHED (devicectl --console) with the autorun env and stream
# the app's stdout live (the `[autorun] …` prints). Blocks until the app exits / Ctrl-C.
# Best for diagnosing a failed bench — you watch exactly where the harness gets.
cmd_console() {
  local spec="${1:-custom:speed:Console diagnostic autorun.}"
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"
  local dev; dev="$(resolve_device)"
  local run_id="ios-console-$(date +%Y%m%d-%H%M%S)"
  note "attached launch ($spec), runID=$run_id — Ctrl-C to detach"
  local env_json
  env_json="$(QV_SPEC="$spec" QV_RUNID="$run_id" python3 -c '
import json, os
print(json.dumps({
    "QWENVOICE_DEBUG": "1",
    "QVOICE_IOS_DEVICE_RUN_ID": os.environ["QV_RUNID"],
    "QVOICE_IOS_AUTORUN": os.environ["QV_SPEC"],
}))')"
  xcrun devicectl device process launch --device "$dev" --console --terminate-existing \
    -e "$env_json" "$BUNDLE_ID"
}

# pull [dest]: copy the diagnostics mirror to dest (default build/ios-diagnostics).
# IMPORTANT: devicectl `copy from` can read the app's OWN data container
# (appDataContainer) but NOT the App-Group container — any App-Group source fails with
# a bogus "File paths cannot contain '..'". So IOSAutorunHarness mirrors the sentinel +
# engine telemetry to Library/Caches/Vocello/diagnostics in the app container, and we
# pull from there. devicectl copies the SOURCE DIR'S CONTENTS into dest.
cmd_pull() {
  local dest="${1:-$ROOT_DIR/build/ios-diagnostics}"
  local dev; dev="$(resolve_device)"
  mkdir -p "$dest"
  note "pulling diagnostics from app container → $dest"
  # 1>&2: keep devicectl chatter off this function's stdout (reserved for the path).
  xcrun devicectl device copy from --device "$dev" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Library/Caches/Vocello/diagnostics" --destination "$dest" 1>&2 \
    || die "could not pull diagnostics (has an autorun happened on THIS installed build?)"
  printf '%s\n' "$dest"
}

cmd_bench() {
  require_team
  local spec="custom:speed:" label=""
  # parse: first non-flag arg = spec; --label "note"; --sim-device <profile>
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="${2:-}"; shift 2 ;;
      --label=*) label="${1#*=}"; shift ;;
      # Restriction simulation (memory dimension only): forwards
      # QVOICE_IOS_SIM_DEVICE so the app clamps its effective per-process
      # limit to the profile's entitled budget (iphone15pro → 5000 MB).
      # Rows self-stamp notes.simulatedDevice; GPU/thermal are NOT simulated.
      --sim-device) export QVOICE_IOS_SIM_DEVICE="${2:-}"; shift 2 ;;
      --sim-device=*) export QVOICE_IOS_SIM_DEVICE="${1#*=}"; shift ;;
      *) spec="$1"; shift ;;
    esac
  done
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"   # bare text → custom:speed:<text>

  cmd_build
  cmd_install
  local run_id; run_id="$(cmd_launch "$spec" | tail -1)"

  local timeout="${QVOICE_IOS_BENCH_TIMEOUT:-300}"
  local dest="$ROOT_DIR/build/ios-diagnostics"
  rm -rf "$dest"
  note "waiting for autorun sentinel (runID=$run_id, timeout=${timeout}s)…"
  local waited=0 sentinel=""
  while (( waited < timeout )); do
    sleep 10; waited=$((waited + 10))
    cmd_pull "$dest" >/dev/null 2>&1 || true
    # devicectl nesting varies, so locate the sentinel by name+runID rather than a fixed path.
    sentinel="$(find "$dest" -name autorun-done.json -path "*/${run_id}/*" 2>/dev/null | head -1)"
    if [[ -n "$sentinel" && -f "$sentinel" ]]; then
      note "sentinel found after ${waited}s"
      break
    fi
    note "…still generating (${waited}s)"
  done

  [[ -n "$sentinel" && -f "$sentinel" ]] || die "no sentinel after ${timeout}s — autorun didn't write. Diagnose live with: $0 console \"$spec\""

  # The summarizer reads <dir>/engine/generations.jsonl — find the dir that holds it.
  local diag="$dest"
  local engine_jsonl; engine_jsonl="$(find "$dest" -path '*/engine/generations.jsonl' 2>/dev/null | head -1)"
  [[ -n "$engine_jsonl" ]] && diag="$(dirname "$(dirname "$engine_jsonl")")"

  note "── autorun result ─────────────────────────────"
  # Heredoc (quoted delimiter) so the Python body needs no shell-quote escaping.
  python3 - "$sentinel" <<'PY' >&2 || true
import json, sys
r = json.load(open(sys.argv[1]))
def num(x): return x if isinstance(x, (int, float)) else 0.0
print("  status   :", r.get("status"))
print("  mode     :", r.get("mode"), "/", r.get("variant"))
print("  model    :", r.get("modelID"))
if r.get("status") == "ok":
    print("  audio    : %.2fs   wall %.2fs   rtf %.2f"
          % (num(r.get("durationSeconds")), num(r.get("wallSeconds")), num(r.get("realtimeFactor"))))
    print("  finish   :", r.get("finishReason"))
    print("  out      :", r.get("audioPath"))
else:
    print("  error    :", r.get("error"))
print("  device   :", r.get("deviceModel"), r.get("systemName"), r.get("systemVersion"))
PY

  note "── telemetry summary (engine decode / RTF / audioQC / RAM) ──"
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag" \
    ${label:+--label "$label"} >&2 || warn "summarizer found no engine rows (was QWENVOICE_DEBUG=1 honored?)"

  # Exit non-zero on a failed generation so CI/automation can gate on it.
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status")=="ok" else 1)' "$sentinel"
}

# ui-test [only]: run the VocelloiOSUITests XCUITest suite ON THE DEVICE (signed). This is
# Apple's official on-device UI-test framework — the sanctioned on-device UI automation,
# distinct from the deprecated screen-mirror UI-driving. Optional [only] scopes the run
# (e.g. VocelloiOSUITests/VocelloiOSSheetUITests or .../testVoicePickerSelectAndClose).
cmd_ui_test() {
  require_team
  local only="${1:-}"
  local dev; dev="$(resolve_device)"
  note "running VocelloiOSUITests on device $dev (signed XCUITest)${only:+ — only $only}"
  mkdir -p "$DERIVED"
  export UI_TEST_SCREENSHOT_DIR="$DERIVED/uitest-screenshots"
  local log="$DERIVED/device-uitest.log"
  local -a only_args=()
  [[ -n "$only" ]] && only_args=( -only-testing:"$only" )
  set +e
  xcodebuild test \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "id=$dev" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$QWENVOICE_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
    ${only_args[@]+"${only_args[@]}"} \
    2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  if grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
    note "device UI tests PASSED"
  else
    die "device UI tests did not report TEST SUCCEEDED (exit $status; see $log)"
  fi
}

main() {
  local sub="${1:-help}"; shift || true
  # Auto-start iPhone Mirroring before any device-touching command (observation + keeps a
  # locked device reachable). `mirror` calls ensure_mirror itself; help/none skip it.
  case "$sub" in
    doctor|build|install|launch|console|pull|bench|shot|ui-test) ensure_mirror ;;
  esac
  case "$sub" in
    doctor)  cmd_doctor "$@" ;;
    build)   cmd_build "$@" ;;
    install) cmd_install "$@" ;;
    launch)  cmd_launch "$@" ;;
    console) cmd_console "$@" ;;
    mirror)  cmd_mirror "$@" ;;
    shot)    cmd_shot "$@" ;;
    pull)    cmd_pull "$@" ;;
    bench)   cmd_bench "$@" ;;
    ui-test) cmd_ui_test "$@" ;;
    help|-h|--help)
      sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//' >&2 ;;
    *) die "unknown subcommand '$sub' (try: doctor|build|install|launch|console|mirror|shot|pull|bench|ui-test|help)" ;;
  esac
}

main "$@"
