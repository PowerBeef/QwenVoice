#!/usr/bin/env bash
# On-device iPhone build/test driver for Vocello — CoreDevice via `devicectl`.
# iPhone Mirroring is used for observation and to keep a locked device reachable to
# CoreDevice; `ui-test` additionally requires the phone unlocked once for the XCUITest
# automation auth handshake (bench/launch work with a locked phone).
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
#   scripts/ios_device.sh ui-test [--all|--cold] [only]
#                                                 # device-safe UI tests (default: Smoke+Sheet+OnDeviceDownload)
#   scripts/ios_device.sh crashes [--test]         # pull + symbolicate on-device crash/hang diagnostics (MetricKit)
#   scripts/ios_device.sh debug [spec]             # attached launch + LLDB attach guidance (get-task-allow build)
#   scripts/ios_device.sh logs [spec]              # attached launch teeing stdout → build/ios-logs/<run>.log
#   scripts/ios_device.sh profile [spec]           # Instruments/xctrace trace of an autorun generation (burn-in-safe)
#   scripts/ios_device.sh preflight                # one-shot readiness (mirror+device+signing+app+dSYM; unlock advisory)
#   scripts/ios_device.sh test [--all|--cold] [only] # ui-test + single verdict + build/ios/uitest-artifacts/
#   scripts/ios_device.sh review [--baseline]        # on-device UI capture tour + baseline diff (burn-in-aware)
#   scripts/ios_device.sh gate                 # pre-merge gate: preflight → test → crashes → verdict
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
  local max_wait="${1:-30}"
  if pgrep -fq "iPhone Mirroring" 2>/dev/null \
     && xcrun devicectl list devices 2>/dev/null | grep -qi "available"; then
    return 0   # already mirroring and a device is reachable
  fi
  note "starting iPhone Mirroring (observation; keeps a locked device reachable, OLED-safe)…"
  open -a "$MIRROR_APP" >/dev/null 2>&1 || warn "could not launch iPhone Mirroring ($MIRROR_APP)"
  local waited=0
  local sleep_s=3
  while (( waited < max_wait )); do
    if xcrun devicectl list devices 2>/dev/null | grep -qi "available"; then
      note "iPhone Mirroring up; device reachable."
      return 0
    fi
    sleep "$sleep_s"; waited=$((waited + sleep_s))
    if (( sleep_s < 6 )); then sleep_s=$((sleep_s + 1)); fi
  done
  warn "device not 'available' yet — LOCK your iPhone (or wait for Auto-Lock) so iPhone Mirroring connects, then re-run."
}

# Strict preflight for XCUITest: mirroring + devicectl availability + unlock guidance.
ensure_device_ready() {
  [[ "${QVOICE_IOS_NO_MIRROR:-}" == "1" ]] || ensure_mirror 60
  local dev
  dev="$(resolve_device)" || die "could not resolve a target device"
  local tmp; tmp="$(mktemp)"
  if ! xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "devicectl could not list devices — connect USB, trust this Mac, enable Developer Mode, and confirm iPhone Mirroring is connected"
  fi
  if ! python3 - "$tmp" "$dev" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
target = sys.argv[2]
devs = (data.get("result") or {}).get("devices") or []
match = next((d for d in devs if d.get("identifier") == target), None)
if not match:
    sys.exit(2)
cp = match.get("connectionProperties") or {}
tunnel = cp.get("tunnelState", "")
pairing = cp.get("pairingState", "")
if tunnel not in ("connected", "available") and pairing != "paired":
    sys.exit(3)
PY
  then
    local code=$?
    rm -f "$tmp"
    [[ $code -eq 2 ]] && die "target device $dev not found in devicectl list"
    [[ $code -eq 3 ]] && die "device $dev is not reachable — unlock iPhone once, confirm USB trust + iPhone Mirroring, then re-run ui-test"
    die "device readiness check failed (exit $code)"
  fi
  rm -f "$tmp"
  note "XCUITest preflight OK on $dev — unlock the iPhone once before tests start (automation auth handshake). bench/launch work with a locked phone."
}

# mirror: start/foreground iPhone Mirroring + confirm the device is reachable (manual use).
cmd_mirror() { ensure_mirror; }

# shot [out.png]: capture the iPhone Mirroring window (the live device screen) to a PNG, for
# visual UI review on REAL hardware. devicectl has no screenshot and this Mac has no
# libimobiledevice, so we screencapture the Mirroring window region.
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

  # Preserve this build's dSYM so `crashes` can symbolicate MetricKit/.ips payloads.
  local dsym_src="$DERIVED/Build/Products/Release-iphoneos/Vocello.app.dSYM"
  if [[ -d "$dsym_src" ]]; then
    local dsym_dst="$ROOT_DIR/build/ios/dsyms/Vocello.app.dSYM"
    rm -rf "$dsym_dst"
    mkdir -p "$(dirname "$dsym_dst")"
    cp -R "$dsym_src" "$dsym_dst"
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Info.plist" \
      > "$(dirname "$dsym_dst")/build-version.txt" 2>/dev/null || true
    note "preserved dSYM → $dsym_dst (for crash symbolication)"
  else
    warn "no dSYM produced — crash symbolication won't be available for this build"
  fi

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

UI_TEST_DEFAULT_CLASSES=(
  "VocelloiOSUITests/VocelloiOSSmokeUITests"
  "VocelloiOSUITests/VocelloiOSSheetUITests"
  "VocelloiOSUITests/VocelloiOSOnDeviceDownloadUITests"
)
UI_TEST_COLD_CLASSES=(
  "VocelloiOSUITests/VocelloiOSColdGenerationUITests"
)

_ui_test_build_for_testing() {
  local dev="$1"
  require_team
  local team; team="$(derive_team)"
  note "building $SCHEME + VocelloiOSUITests for testing on $dev"
  mkdir -p "$DERIVED"
  local log="$DERIVED/device-uitest-build.log"
  local mode="auto"
  [[ "${QVOICE_IOS_MANUAL_SIGN:-}" == "1" ]] && mode="manual"
  build_sign_args "$mode" "$team"
  set +e
  xcodebuild build-for-testing \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "id=$dev" -derivedDataPath "$DERIVED" \
    "${SIGN_ARGS[@]}" \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    2>&1 | tee "$log"
  local st=${PIPESTATUS[0]}; set -e
  [[ $st -eq 0 ]] || die "build-for-testing failed (see $log)"
  [[ -d "$APP_PATH" ]] || die "build-for-testing finished but $APP_PATH is missing"
}

_ui_test_log_needs_unlock_retry() {
  local log="$1"
  grep -qiE 'Unlock iPhone|ApproveFailed|device locked|SFAuthenticationErrorCodeApproveFailedToPost' "$log"
}

_ui_test_latest_xcresult() {
  find "$DERIVED/Logs/Test" -name '*.xcresult' -type d 2>/dev/null | sort | tail -1
}

_run_ui_test_once() {
  local dev="$1"
  local log="$2"
  shift 2
  local -a only_args=( "$@" )
  set +e
  if [[ -s "$log" ]]; then
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination "id=$dev" -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$QWENVOICE_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
      ${only_args[@]+"${only_args[@]}"} \
      2>&1 | tee -a "$log"
  else
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination "id=$dev" -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$QWENVOICE_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
      ${only_args[@]+"${only_args[@]}"} \
      2>&1 | tee "$log"
  fi
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

# ui-test [--all|--cold] [only]: run VocelloiOSUITests on the device (signed XCUITest).
# Default scope is the device-safe trio (Smoke + Sheet + OnDeviceDownload). Optional
# [only] scopes to one class or method, e.g. VocelloiOSUITests/VocelloiOSSheetUITests.
cmd_ui_test() {
  require_team
  local scope="default"
  local only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) scope="all"; shift ;;
      --cold) scope="cold"; shift ;;
      -*) die "unknown ui-test flag: $1 (try --all, --cold, or a VocelloiOSUITests/… target)" ;;
      *) only="$1"; shift ;;
    esac
  done

  ensure_device_ready
  local dev; dev="$(resolve_device)"
  note "running VocelloiOSUITests on device $dev (scope: ${only:-$scope})"
  mkdir -p "$DERIVED"
  export UI_TEST_SCREENSHOT_DIR="$DERIVED/uitest-screenshots"
  local log="$DERIVED/device-uitest.log"

  _ui_test_build_for_testing "$dev"
  note "installing host app before XCUITest attach"
  xcrun devicectl device install app --device "$dev" "$APP_PATH"

  local attempt=1
  local status=0
  local all_ok=1
  local -a run_targets=()
  if [[ -n "$only" ]]; then
    run_targets=( "$only" )
  elif [[ "$scope" == "default" ]]; then
    run_targets=( "${UI_TEST_DEFAULT_CLASSES[@]}" )
  elif [[ "$scope" == "cold" ]]; then
    run_targets=( "${UI_TEST_COLD_CLASSES[@]}" )
  else
    run_targets=( "" )
  fi

  while (( attempt <= 2 )); do
    if (( attempt > 1 )); then
      warn "retrying ui-test after unlock/auth failure — unlock the iPhone, dismiss any automation prompt, then wait…"
      sleep 8
      : >"$log"
    fi
    status=0
    all_ok=1
    : >"$log"
    if ((${#run_targets[@]} == 0)); then
      set +e
      _run_ui_test_once "$dev" "$log"
      status=$?
      set -e
      (( status != 0 )) && all_ok=0
    else
      local target
      for target in "${run_targets[@]}"; do
        note "ui-test class: $target"
        set +e
        _run_ui_test_once "$dev" "$log" -only-testing:"$target"
        local one=$?
        set -e
        if (( one != 0 )); then
          all_ok=0
          status=$one
          break
        fi
        if _ui_test_log_needs_unlock_retry "$log"; then
          all_ok=0
          break
        fi
      done
    fi
    if (( all_ok == 1 )) && grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
      note "device UI tests PASSED"
      return 0
    fi
    if (( attempt == 1 )) && _ui_test_log_needs_unlock_retry "$log"; then
      attempt=$((attempt + 1))
      continue
    fi
    break
  done

  local xcresult; xcresult="$(_ui_test_latest_xcresult || true)"
  [[ -n "$xcresult" ]] && warn "xcresult bundle: $xcresult"
  warn "ui-test log: $log"
  [[ -d "$UI_TEST_SCREENSHOT_DIR" ]] && warn "screenshots: $UI_TEST_SCREENSHOT_DIR"
  die "device UI tests did not report TEST SUCCEEDED (exit ${status:-1}; see $log)"
}

# crashes [--test]: pull + symbolicate on-device crash/hang diagnostics (MetricKit
# `MXDiagnosticPayload` + the NSException fast path from IOSCrashObserver) against the
# build's preserved dSYM. `--test` deliberately crashes the app (QVOICE_IOS_CRASH_TEST=1)
# then relaunches so the observer flushes the payload — to verify the whole
# capture→pull→symbolicate lane end-to-end. Burns-in safe (headless; phone can stay locked).
cmd_crashes() {
  local test_mode=0
  [[ "${1:-}" == "--test" ]] && test_mode=1
  ensure_mirror
  local dev; dev="$(resolve_device)"

  if [[ $test_mode -eq 1 ]]; then
    note "crash-lane self-test: deliberately crashing the app (QVOICE_IOS_CRASH_TEST=1)…"
    [[ -d "$APP_PATH" ]] || cmd_build
    cmd_install >/dev/null
    xcrun devicectl device process launch --device "$dev" --terminate-existing \
      -e '{"QVOICE_IOS_CRASH_TEST":"1"}' "$BUNDLE_ID" >&2 || true
    sleep 4
    note "relaunching so IOSCrashObserver receives + writes the prior crash payload…"
    xcrun devicectl device process launch --device "$dev" --terminate-existing "$BUNDLE_ID" >&2 || true
    sleep 6
  fi

  local dest="$ROOT_DIR/build/ios-diagnostics"
  rm -rf "$dest"
  cmd_pull "$dest" >/dev/null || die "could not pull diagnostics (run an autorun first, or use --test)"
  local crash_dir; crash_dir="$(find "$dest" -type d -name crashes 2>/dev/null | head -1)"
  if [[ -z "$crash_dir" ]] || [[ -z "$(find "$crash_dir" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
    note "no crash payloads in the pulled diagnostics — nothing to symbolicate."
    return 0
  fi

  note "── crash payloads ($crash_dir) ──"
  find "$crash_dir" -maxdepth 1 -type f | sort

  local dsym="$ROOT_DIR/build/ios/dsyms/Vocello.app.dSYM"
  if [[ ! -d "$dsym" ]]; then
    warn "no preserved dSYM at $dsym — run '$0 build' to enable symbolication."
    return 0
  fi

  note "── symbolication (via xcsym; install axiom-tools if missing) ──"
  local f
  for f in "$crash_dir"/*; do
    [[ -f "$f" ]] || continue
    if command -v xcsym >/dev/null 2>&1; then
      xcsym crash "$f" --dsym "$dsym" 2>&1 || warn "xcsym failed on $(basename "$f")"
    else
      warn "xcsym not on PATH — symbolicating $(basename "$f") needs axiom-tools:"
      warn "  xcsym crash \"$f\" --dsym \"$dsym\"   (or dispatch the axiom:crash-analyzer agent)"
    fi
  done
}

# debug [spec]: build+install the get-task-allow build, then an attached console launch
# and the exact LLDB attach command. The LLDB session itself is interactive (paste it, or
# use the XcodeBuildMCP device/debugging workflow, or Xcode → Debug → Attach to Process).
# Burns-in safe (headless/locked works).
cmd_debug() {
  local spec="${1:-}"
  [[ -d "$APP_PATH" ]] || cmd_build
  cmd_install >/dev/null
  local dev; dev="$(resolve_device)"
  note "debug: get-task-allow build installed on $dev — LLDB-attachable."
  note "  lldb"
  note "  (lldb) process attach --name Vocello --device $dev"
  note "  (or XcodeBuildMCP device/debugging workflow, or Xcode → Debug → Attach to Process)"
  if [[ -n "$spec" ]]; then
    note "attached launch ($spec) — Ctrl-C to detach"
    cmd_console "$spec"
  else
    note "attached launch (console) — Ctrl-C to detach"
    cmd_console
  fi
}

# logs [spec]: attached launch teeing the app's stdout/stderr to a retained, greppable
# file under build/ios-logs/ (incl. [autorun]/[QVoiceiOSApp] prints + engine signposts).
# Replaces the ephemeral `console` stream with a saved log. Burns-in safe (headless).
cmd_logs() {
  local spec="${1:-custom:speed:Log capture autorun.}"
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"
  ensure_mirror
  local dev; dev="$(resolve_device)"
  local run_id="ios-logs-$(date +%Y%m%d-%H%M%S)"
  local out="$ROOT_DIR/build/ios-logs/${run_id}.log"
  mkdir -p "$(dirname "$out")"
  note "capturing attached launch logs → $out (Ctrl-C to stop)"
  local env_json
  env_json="$(QV_SPEC="$spec" QV_RUNID="$run_id" python3 -c '
import json, os
print(json.dumps({
    "QWENVOICE_DEBUG": "1",
    "QVOICE_IOS_DEVICE_RUN_ID": os.environ["QV_RUNID"],
    "QVOICE_IOS_AUTORUN": os.environ["QV_SPEC"],
}))')"
  xcrun devicectl device process launch --device "$dev" --console --terminate-existing \
    -e "$env_json" "$BUNDLE_ID" 2>&1 | tee "$out"
  note "saved $out"
}

# profile [spec]: record an Instruments/xctrace trace while the autorun harness runs one
# generation on-device (burns-in safe — headless, screen dark). Default template
# 'Time Profiler'; override with QVOICE_IOS_PROFILE_TEMPLATE ('Allocations', …) and the
# capture window with QVOICE_IOS_PROFILE_DURATION (seconds, default 90). The engine emits
# OSSignpost intervals under com.qwenvoice.engine / com.patricedery.vocello — use a
# signpost-bearing template (or the os_signpost instrument) to capture them. Produces
# build/ios/profile-<ts>.trace + the in-app telemetry summary for the same run.
cmd_profile() {
  local spec="${1:-custom:speed:Profile autorun.}"
  [[ "$spec" == *:* ]] || spec="custom:speed:$spec"
  require_team
  local template="${QVOICE_IOS_PROFILE_TEMPLATE:-Time Profiler}"
  local duration="${QVOICE_IOS_PROFILE_DURATION:-90}"
  local dev; dev="$(resolve_device)"
  ensure_mirror
  command -v xctrace >/dev/null 2>&1 \
    || die "xctrace not found (install Xcode); or dispatch the axiom:performance-profiler agent"

  [[ -d "$APP_PATH" ]] || cmd_build
  cmd_install >/dev/null
  local trace="$ROOT_DIR/build/ios/profile-$(date +%Y%m%d-%H%M%S).trace"
  mkdir -p "$(dirname "$trace")"

  note "profile: template='$template', ${duration}s, device=$dev (start tracer, then autorun)"
  # Start the tracer FIRST (attach mode waits for 'Vocello') so it captures from launch.
  xctrace record --device "$dev" --template "$template" \
    --attach "Vocello" --time-limit "${duration}s" --output "$trace" &
  local xcpid=$!
  sleep 2   # let xctrace begin polling for the attach target
  local run_id; run_id="$(cmd_launch "$spec" | tail -1)"
  note "autorun launched (runID=$run_id); capturing for up to ${duration}s…"
  wait "$xcpid" || true
  [[ -d "$trace" ]] || die "no trace produced at $trace"

  note "trace → $trace"
  note "analyze: open in Instruments, or dispatch axiom:performance-profiler / run: xcprof analyze \"$trace\""

  local dest="$ROOT_DIR/build/ios-diagnostics"
  rm -rf "$dest"
  cmd_pull "$dest" >/dev/null 2>&1 || true
  local diag="$dest"
  local engine_jsonl; engine_jsonl="$(find "$dest" -path '*/engine/generations.jsonl' 2>/dev/null | head -1)"
  [[ -n "$engine_jsonl" ]] && diag="$(dirname "$(dirname "$engine_jsonl")")"
  note "── telemetry for the profiled run ──"
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag" >&2 \
    || warn "no engine telemetry (was QWENVOICE_DEBUG=1 honored?)"
  printf '%s\n' "$trace"
}

# preflight: one-shot readiness check for on-device work — iPhone Mirroring up, device
# reachable, signing team derivable, app + dSYM built. Fails fast (exit non-zero) with
# what's missing. A LOCKED phone can't be auto-detected from the Mac (a locked +
# mirroring device stays 'available' to devicectl), so this prints the unlock advisory
# for ui-test up front instead of guessing.
cmd_preflight() {
  local rc=0
  note "on-device preflight"
  ensure_mirror 60

  local dev; dev="$(resolve_device 2>/dev/null)" || dev=""
  if [[ -z "$dev" ]]; then warn "  device: ✗ none resolved"; rc=1; else printf '  device: %s\n' "$dev" >&2; fi

  if [[ -n "$dev" ]]; then
    local tmp; tmp="$(mktemp)"
    if xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1; then
      python3 - "$tmp" "$dev" <<'PY' >&2 || rc=1
import json, sys
data = json.load(open(sys.argv[1]))
devs = (data.get("result") or {}).get("devices") or []
m = next((d for d in devs if d.get("identifier") == sys.argv[2]), None)
if not m:
    print("  reachability: ✗ device not in devicectl list"); sys.exit(1)
cp = m.get("connectionProperties") or {}
tunnel, pairing = cp.get("tunnelState", ""), cp.get("pairingState", "")
ok = tunnel in ("connected", "available") or pairing == "paired"
print(f"  reachability: {'OK' if ok else 'FAIL'} tunnel={tunnel or '?'} pairing={pairing or '?'}")
sys.exit(0 if ok else 1)
PY
    else
      warn "  reachability: ✗ devicectl list failed"; rc=1
    fi
    rm -f "$tmp"
  fi

  local team; team="$(derive_team 2>/dev/null)"
  if [[ -n "$team" ]]; then
    printf '  signing: OK team %s\n' "$team" >&2
  else
    warn "  signing: ✗ no team (set QWENVOICE_DEVELOPMENT_TEAM or add an Apple Development cert)"; rc=1
  fi

  if [[ -d "$APP_PATH" ]]; then
    printf '  app: OK %s\n' "$APP_PATH" >&2
    if [[ -d "$ROOT_DIR/build/ios/dsyms/Vocello.app.dSYM" ]]; then
      printf '  dsym: OK build/ios/dsyms/Vocello.app.dSYM\n' >&2
    else
      warn "  dsym: ✗ none (run '$0 build' to enable crash symbolication)"
    fi
  else
    warn "  app: ✗ not built (run: $0 build)"; rc=1
  fi

  note "unlock advisory: ui-test needs the iPhone UNLOCKED once (automation auth handshake); bench/launch/profile/crashes/logs work locked."
  (( rc == 0 )) && note "preflight OK" || die "preflight not ready (see above)"
}

# test [--all|--cold] [only]: run VocelloiOSUITests on-device and emit a single verdict +
# gather artifacts under build/ios/uitest-artifacts/<runID>/. Thin wrapper over ui-test
# (same scope flags) run in a subshell so its `die` is captured, plus a best-effort
# xcresulttool summary. Screenshots land via the test app's UI_TEST_SCREENSHOT_DIR. For
# deep .xcresult analysis, dispatch the axiom:test-runner agent on the bundle.
cmd_test() {
  require_team
  local run_id="ios-test-$(date +%Y%m%d-%H%M%S)"
  local artifacts="$ROOT_DIR/build/ios/uitest-artifacts/$run_id"
  mkdir -p "$artifacts"

  # Subshell: cmd_ui_test's `die` (exit) must not kill this function before we parse.
  set +e
  ( cmd_ui_test "$@" )
  local st=$?
  set -e

  local xcresult; xcresult="$(_ui_test_latest_xcresult || true)"
  {
    echo "xcresult: ${xcresult:-<none>}"
    echo "exit: $st"
    if [[ -n "$xcresult" && -d "$xcresult" ]]; then
      xcrun xcresulttool get test-results summary --format json --path "$xcresult" 2>/dev/null \
        || echo "(xcresulttool summary unavailable — open the .xcresult in Xcode)"
    fi
  } >"$artifacts/verdict.json"
  cat "$artifacts/verdict.json" >&2

  local shots="$DERIVED/uitest-screenshots"
  [[ -d "$shots" ]] && cp -R "$shots" "$artifacts/screenshots" 2>/dev/null || true

  if (( st == 0 )); then
    note "test verdict: PASS · artifacts → $artifacts"
  else
    warn "test verdict: FAIL (exit $st) · artifacts → $artifacts"
    exit "$st"
  fi
}

# review [--baseline]: capture on-device screenshots of the key screens (XCUITest tour:
# VocelloiOSReviewTourUITests) for visual review + baseline diffing. Burns-in aware — the
# tour opens each sheet only long enough to capture, then dismisses it. Captures land in
# build/ios/review-shots/<run>/; committed baselines live in docs/ios-review-baselines/.
# `--baseline` seeds/updates baselines from this run. The perceptual diff is a vision-MCP
# step (ui_diff_check / axiom:screenshot-validator); this verb captures + does a
# file-level baseline check and prints the pairs to diff.
cmd_review() {
  require_team
  local baseline_mode=0
  [[ "${1:-}" == "--baseline" ]] && baseline_mode=1

  local run_id="ios-review-$(date +%Y%m%d-%H%M%S)"
  local shots="$ROOT_DIR/build/ios/review-shots/$run_id"
  local baselines="$ROOT_DIR/docs/ios-review-baselines"
  mkdir -p "$shots" "$baselines"

  note "review: capturing the on-device UI tour (runID=$run_id)"
  set +e
  ( cmd_ui_test "VocelloiOSUITests/VocelloiOSReviewTourUITests" )
  local st=$?
  set -e

  local src="$DERIVED/uitest-screenshots"
  [[ -d "$src" ]] && cp -R "$src/." "$shots/" 2>/dev/null || true
  note "captures → $shots"

  if (( baseline_mode == 1 )); then
    if ls "$shots"/*.png >/dev/null 2>&1; then
      cp "$shots"/*.png "$baselines/"
      note "baselines seeded/updated → $baselines (review + git add + commit)"
    else
      warn "no PNGs in $shots to seed"
    fi
    return "$st"
  fi

  note "── baseline pairs (perceptual diff via vision MCP) ──"
  local any=0 png name
  for png in "$shots"/*.png; do
    [[ -f "$png" ]] || continue
    any=1
    name="$(basename "$png")"
    if [[ -f "$baselines/$name" ]]; then
      printf '  DIFF  %s\n' "$name" >&2
      printf '        actual:   %s\n' "$png" >&2
      printf '        baseline: %s\n' "$baselines/$name" >&2
    else
      printf '  NEW   %s  (no baseline — run: %s review --baseline)\n' "$name" "$0" >&2
    fi
  done
  (( any == 0 )) && warn "no captures produced (did the tour run?)"
  note "diff each pair with mcp__zai-mcp-server__ui_diff_check (expected=baseline, actual=capture), or axiom:screenshot-validator."

  (( st == 0 )) && note "review tour OK" || warn "review tour had failures (exit $st)"
  return "$st"
}

# gate: one-command on-device pre-merge gate — preflight → test (default scope) → crashes
# (post-run; expect none on a clean build) → a single PASS/FAIL verdict + per-step logs +
# a verdict.txt under build/ios/gate-<run>/. Burns-in safe. Deeper dives (profile, review,
# bench/listening-pass) are separate verbs — run them pre-release, not on every merge.
cmd_gate() {
  require_team
  local run_id="ios-gate-$(date +%Y%m%d-%H%M%S)"
  local gate_dir="$ROOT_DIR/build/ios/gate-$run_id"
  mkdir -p "$gate_dir"
  local verdict="$gate_dir/verdict.txt"
  local overall=0

  { echo "Vocello on-device gate — $run_id"; echo; } | tee "$verdict"

  note "gate 1/3: preflight"
  if ( cmd_preflight ) >>"$gate_dir/preflight.log" 2>&1; then
    echo "preflight: PASS" | tee -a "$verdict"
  else
    echo "preflight: FAIL (see preflight.log)" | tee -a "$verdict"; overall=1
  fi

  note "gate 2/3: test (default scope)"
  if ( cmd_test ) >>"$gate_dir/test.log" 2>&1; then
    echo "test: PASS" | tee -a "$verdict"
  else
    echo "test: FAIL (see test.log)" | tee -a "$verdict"; overall=1
  fi

  note "gate 3/3: crashes (post-run check; expect none)"
  if ( cmd_crashes ) >>"$gate_dir/crashes.log" 2>&1; then
    echo "crashes: none/new (see crashes.log)" | tee -a "$verdict"
  else
    echo "crashes: check failed (see crashes.log)" | tee -a "$verdict"
  fi

  echo | tee -a "$verdict"
  if (( overall == 0 )); then
    echo "GATE: PASS" | tee -a "$verdict"
    note "gate PASS · $gate_dir"
  else
    echo "GATE: FAIL" | tee -a "$verdict"
    warn "gate FAIL · $gate_dir"
  fi
  cat "$verdict" >&2
  exit "$overall"
}

main() {
  local sub="${1:-help}"; shift || true
  # Auto-start iPhone Mirroring before any device-touching command (observation + keeps a
  # locked device reachable). `mirror` calls ensure_mirror itself; help/none skip it.
  case "$sub" in
    doctor|build|install|launch|console|pull|bench|shot|crashes|debug|logs|profile) ensure_mirror ;;
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
    crashes) cmd_crashes "$@" ;;
    debug)   cmd_debug "$@" ;;
    logs)    cmd_logs "$@" ;;
    profile) cmd_profile "$@" ;;
    preflight) cmd_preflight "$@" ;;
    test)      cmd_test "$@" ;;
    review)    cmd_review "$@" ;;
    gate)      cmd_gate "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2 ;;
    *) die "unknown subcommand '$sub' (try: doctor|build|install|launch|console|mirror|shot|pull|bench|ui-test|crashes|debug|logs|profile|preflight|test|review|gate|help)" ;;
  esac
}

main "$@"
