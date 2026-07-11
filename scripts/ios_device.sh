#!/usr/bin/env bash
# On-device iPhone build/test driver for Vocello — CoreDevice via `devicectl`.
# Repository scripts own build, launch, telemetry, crash, and physical-device proof.
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
#   scripts/ios_device.sh pull [dest]             # pull the app-container diagnostics mirror
#   scripts/ios_device.sh bench [spec] [--label "note"]
#   scripts/ios_device.sh lang-bench [--subset quick|full] [--label "note"]
#                                                 # headless language-hint matrix (autorun)
#   scripts/ios_device.sh crashes [--test]         # pull + symbolicate on-device crash/hang diagnostics (MetricKit)
#   scripts/ios_device.sh debug [spec]             # attached launch + LLDB attach guidance (get-task-allow build)
#   scripts/ios_device.sh logs [spec]              # attached launch teeing stdout → build/ios-logs/<run>.log
#   scripts/ios_device.sh profile [spec]           # Instruments/xctrace trace of an autorun generation (burn-in-safe)
#   scripts/ios_device.sh preflight                # paired-device, signing, build, and dSYM readiness
#   scripts/ios_device.sh device-state [--json|--json-v2] [watch [--interval N] [--count N]]
#                                                 # paired-device reachability and lock state
#   scripts/ios_device.sh gate                 # explicit device gate: preflight → generation → crashes → verdict
#                                              # (generation needs Speed on device; QVOICE_GATE_SKIP_GENERATION=1 to skip)
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

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="VocelloiOS"
CONFIG="Release"
BUNDLE_ID="com.patricedery.vocello"
APP_GROUP="group.com.patricedery.vocello.shared"
# Single shared physical-device iOS DerivedData tree.
# Swept/reclaimed by scripts/clean_build_caches.sh (--aggressive) + build.sh's prune.
DERIVED="$ROOT_DIR/build/ios"
APP_PATH="$DERIVED/Build/Products/Release-iphoneos/Vocello.app"
PROJECT="$ROOT_DIR/QwenVoice.xcodeproj"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

# Reuse the shared storage-bloat advisory (warn-only; never deletes).
. "$ROOT_DIR/scripts/lib/build_cache.sh"
. "$ROOT_DIR/scripts/lib/ios_device_state.sh"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# device-state [--json|--json-v2] [watch [--interval N] [--count N]]
# Exit codes: 0 READY · 14 DEVICE_UNREACHABLE.
cmd_device_state() {
  local as_json=0 json_v2=0 watch=0 interval=2 count=3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) as_json=1; shift ;;
      --json-v2) as_json=1; json_v2=1; shift ;;
      watch) watch=1; shift ;;
      --interval) interval="${2:?}"; shift 2 ;;
      --count) count="${2:?}"; shift 2 ;;
      *) die "unknown device-state flag: $1" ;;
    esac
  done

  local dev; dev="$(resolve_device 2>/dev/null || true)"

  if (( watch )); then
    local line verdict detail
    line="$(probe_device_state_watch "$dev" "$interval" "$count")"
    verdict="${line%%|*}"
    detail="${line#*|}"
    if (( as_json && json_v2 )); then
      probe_device_state_json "$dev"
    elif (( as_json )); then
      VERDICT="$verdict" DETAIL="$detail" ADVICE="$(device_state_advice "$verdict")" python3 -c '
import json, os
print(json.dumps({"verdict": os.environ["VERDICT"], "detail": os.environ["DETAIL"], "advice": os.environ["ADVICE"], "probeVersion": 1}))'
    else
      note "device state (watch): $verdict — $detail"
      note "  $(device_state_advice "$verdict")"
    fi
    exit "$(device_state_exit_code "$verdict")"
  fi

  if (( as_json && json_v2 )); then
    probe_device_state_json "$dev"
    local line verdict
    line="$(probe_device_state "$dev")"
    verdict="${line%%|*}"
    exit "$(device_state_exit_code "$verdict")"
  fi

  local line verdict detail
  line="$(probe_device_state "$dev")"
  verdict="${line%%|*}"
  detail="${line#*|}"
  if (( as_json )); then
    VERDICT="$verdict" DETAIL="$detail" ADVICE="$(device_state_advice "$verdict")" python3 -c '
import json, os
print(json.dumps({
    "verdict": os.environ["VERDICT"],
    "detail": os.environ["DETAIL"],
    "advice": os.environ["ADVICE"],
    "probeVersion": 1,
}))'
  else
    note "device state: $verdict — $detail"
    note "  $(device_state_advice "$verdict")"
  fi
  exit "$(device_state_exit_code "$verdict")"
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

# Resolve the target device id. Prefer $QVOICE_IOS_DEVICE_ID; otherwise auto-pick a
# connected/paired CoreDevice (prefers "iPhone 17 Pro" when multiple are paired).
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
if not cands:
    sys.exit(3)
preferred = "iPhone 17 Pro"
for d in cands:
    props = d.get("deviceProperties") or {}
    if props.get("name") == preferred:
        print(d.get("identifier", ""))
        sys.exit(0)
if len(cands) == 1:
    print(cands[0].get("identifier", ""))
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
    local ent; ent="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
    if grep -q 'application-groups' <<<"$ent"; then
      printf '  app group: OK (%s)\n' "$APP_GROUP" >&2
    else
      warn "app group missing from signed app — rebuild after fixing CODE_SIGN_ENTITLEMENTS (run: $0 build)"
    fi
    if grep -q 'increased-memory-limit' <<<"$ent"; then
      printf '  increased-memory-limit: OK\n' >&2
    else
      warn "increased-memory-limit missing from signed app"
    fi
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
# Optional QVOICE_LAUNCH_RUN_ID overrides the per-launch diagnostics run id (lang-bench).
cmd_launch() {
  local spec="${1:-}"
  local dev; dev="$(resolve_device)"
  if [[ -n "$spec" ]]; then
    local run_id="${QVOICE_LAUNCH_RUN_ID:-ios-$(date +%Y%m%d-%H%M%S)}"
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

# wait_autorun_sentinel RUN_ID TIMEOUT DEST
# Polls pulled diagnostics until autorun-done.json exists for RUN_ID.
# Returns 0 and prints the sentinel path on success; dies on timeout/interference.
wait_autorun_sentinel() {
  local run_id="$1" timeout="${2:-300}" dest="$3"
  local waited=0 sentinel=""
  local interference_streak=0 interference_state=""
  while (( waited < timeout )); do
    sleep 10
    waited=$((waited + 10))
    cmd_pull "$dest" >/dev/null 2>&1 || true
    sentinel="$(find "$dest" -name autorun-done.json -path "*/${run_id}/*" 2>/dev/null | head -1)"
    if [[ -n "$sentinel" && -f "$sentinel" ]]; then
      note "sentinel found after ${waited}s (runID=$run_id)"
      printf '%s\n' "$sentinel"
      return 0
    fi
    local state verdict
    state="$(probe_device_state 2>/dev/null || true)"
    verdict="${state%%|*}"
    case "$verdict" in
      DEVICE_UNREACHABLE)
        die "run doomed at ${waited}s — $verdict: $(device_state_advice "$verdict") (${state#*|})"
        ;;
      *)
        interference_streak=0
        ;;
    esac
    note "…still generating (${waited}s / runID=$run_id)"
  done
  die "no sentinel after ${timeout}s for runID=$run_id — Device state: $(probe_device_state 2>/dev/null || echo unknown)"
}

# lang-bench [--subset quick|full] [--label "note"]:
# Headless on-device language matrix — one autorun per cell, gated by
# scripts/check_language_hints.py on notes.languageHint vs config/language-bench-matrix.json.
cmd_lang_bench() {
  require_team
  note "lang-bench requires Custom Voice (Speed) on device — install via Settings → Model Downloads if autorun fails"
  local subset="full" label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subset) subset="${2:-full}"; shift 2 ;;
      --subset=*) subset="${1#*=}"; shift ;;
      --label) label="${2:-}"; shift 2 ;;
      --label=*) label="${1#*=}"; shift ;;
      *) die "unknown lang-bench arg '$1' (try --subset quick|full --label \"note\")" ;;
    esac
  done
  [[ "$subset" == "quick" || "$subset" == "full" ]] || die "--subset must be quick or full"

  local matrix="$ROOT_DIR/config/language-bench-matrix.json"
  local corpus="$ROOT_DIR/config/language-bench-corpus.json"
  [[ -f "$matrix" && -f "$corpus" ]] || die "missing language bench config (expected $matrix and $corpus)"

  local run_id="ios-lang-bench-$(date +%Y%m%d-%H%M%S)"
  local artifacts="$ROOT_DIR/build/ios/lang-bench-$run_id"
  local dest="$ROOT_DIR/build/ios-diagnostics"
  local cell_timeout="${QVOICE_IOS_LANG_BENCH_CELL_TIMEOUT:-240}"
  mkdir -p "$artifacts"
  rm -rf "$dest"

  cmd_build
  cmd_install

  export QVOICE_MAC_BENCH_RUN_ID="$run_id"
  if [[ "${QVOICE_LANG_BENCH_SKIP_OUTPUT:-0}" != "1" ]]; then
    export QVOICE_IOS_VERIFY_OUTPUT=1
    note "lang-bench: output verification ON (Speech — grant once in Settings if needed)"
  else
    unset QVOICE_IOS_VERIFY_OUTPUT
  fi
  note "lang-bench: runID=$run_id subset=$subset → $artifacts"

  local cell_json cell_count=0 cell_fail=0
  while IFS= read -r cell_json; do
    [[ -n "$cell_json" ]] || continue
    cell_count=$((cell_count + 1))
    local cell_id mode variant ui_hint text child_run_id spec sentinel st
    cell_id="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"])["id"])')"
    mode="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"])["mode"])')"
    variant="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"]).get("variant","speed"))')"
    ui_hint="$(CELL="$cell_json" python3 -c 'import json,os; print(json.loads(os.environ["CELL"]).get("uiHint","auto"))')"
    text="$(CELL="$cell_json" CORPUS="$corpus" python3 -c '
import json, os
cell = json.loads(os.environ["CELL"])
corpus = json.load(open(os.environ["CORPUS"]))
scripts = {e["id"]: e["script"] for e in corpus["languages"]}
print(scripts[cell["scriptLang"]], end="")')"
    child_run_id="${run_id}--${cell_id}"
    spec="${mode}:${variant}:${text}"

    note "lang-bench cell $cell_count: $cell_id ($mode, uiHint=$ui_hint)"
    export QVOICE_LAUNCH_RUN_ID="$child_run_id"
    export QVOICE_MAC_BENCH_CELL="$cell_id"
    if [[ "$ui_hint" == "auto" ]]; then
      unset QVOICE_IOS_AUTORUN_LANG
    else
      export QVOICE_IOS_AUTORUN_LANG="$ui_hint"
    fi

    cmd_launch "$spec" >/dev/null
    set +e
    sentinel="$({ wait_autorun_sentinel "$child_run_id" "$cell_timeout" "$dest"; })"
    wait_st=$?
    set -e
    if (( wait_st != 0 )) || [[ -z "$sentinel" || ! -f "$sentinel" ]]; then
      warn "lang-bench cell $cell_id: timed out or failed (runID=$child_run_id)"
      cell_fail=$((cell_fail + 1))
      continue
    fi
    if ! python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status")=="ok" else 1)' "$sentinel"; then
      warn "lang-bench cell $cell_id: autorun status != ok (see $sentinel)"
      cell_fail=$((cell_fail + 1))
    fi
  done < <(python3 - "$matrix" "$corpus" "$subset" <<'PY'
import json, sys
matrix_path, corpus_path, subset = sys.argv[1:4]
cells = json.load(open(matrix_path))["cells"]
if subset == "quick":
    cells = [c for c in cells if c.get("quick")]
corpus = {e["id"]: e["script"] for e in json.load(open(corpus_path))["languages"]}
for cell in cells:
    cell = dict(cell)
    cell["script"] = corpus[cell["scriptLang"]]
    print(json.dumps(cell, ensure_ascii=False))
PY
)

  unset QVOICE_LAUNCH_RUN_ID QVOICE_MAC_BENCH_RUN_ID QVOICE_MAC_BENCH_CELL QVOICE_IOS_AUTORUN_LANG QVOICE_IOS_VERIFY_OUTPUT

  [[ "$cell_count" -gt 0 ]] || die "lang-bench: no cells for subset=$subset"

  local engine_jsonl diag="$dest"
  engine_jsonl="$(find "$dest" -path '*/engine/generations.jsonl' 2>/dev/null | head -1)"
  [[ -n "$engine_jsonl" ]] && diag="$(dirname "$(dirname "$engine_jsonl")")"

  note "lang-bench: pulled $cell_count cells ($cell_fail autorun failures) — hint gate"
  cp -R "$dest" "$artifacts/diagnostics" 2>/dev/null || true

  local gate_st=0 hint_st=0 output_st=0
  python3 "$ROOT_DIR/scripts/check_language_hints.py" "$diag" \
    --run-id "$run_id" --matrix "$matrix" --corpus "$corpus" --subset "$subset" \
    | tee "$artifacts/hint-gate.txt" || hint_st=$?

  if [[ "${QVOICE_LANG_BENCH_SKIP_OUTPUT:-0}" != "1" ]]; then
    python3 "$ROOT_DIR/scripts/check_language_output.py" "$diag" \
      --run-id "$run_id" --matrix "$matrix" --subset "$subset" \
      | tee "$artifacts/output-gate.txt" || output_st=$?
  fi

  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag" \
    ${label:+--label "$label"} >"$artifacts/summary.txt" 2>&1 || true

  {
    echo "lang-bench runID=$run_id subset=$subset cells=$cell_count autorun_fail=$cell_fail"
    echo "hint_gate=$([[ $hint_st -eq 0 ]] && echo PASS || echo FAIL)"
    if [[ "${QVOICE_LANG_BENCH_SKIP_OUTPUT:-0}" != "1" ]]; then
      echo "output_gate=$([[ $output_st -eq 0 ]] && echo PASS || echo FAIL)"
    else
      echo "output_gate=SKIPPED"
    fi
  } | tee "$artifacts/verdict.txt"

  if (( cell_fail > 0 || hint_st != 0 || output_st != 0 )); then
    die "lang-bench FAIL · $artifacts"
  fi
  note "lang-bench PASS · $artifacts"
}

cmd_bench() {
  require_team
  note "bench requires Custom Voice (Speed) on device — confirm it in Settings → Model Downloads before generation"
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
  local interference_streak=0 interference_state=""
  while (( waited < timeout )); do
    sleep 10; waited=$((waited + 10))
    cmd_pull "$dest" >/dev/null 2>&1 || true
    # devicectl nesting varies, so locate the sentinel by name+runID rather than a fixed path.
    sentinel="$(find "$dest" -name autorun-done.json -path "*/${run_id}/*" 2>/dev/null | head -1)"
    if [[ -n "$sentinel" && -f "$sentinel" ]]; then
      note "sentinel found after ${waited}s"
      break
    fi
    # Interference probe: abort fast instead of polling to the full timeout.
    # Competing UI ownership or a disconnected device dooms the run immediately.
    local state verdict
    state="$(probe_device_state 2>/dev/null || true)"
    verdict="${state%%|*}"
    case "$verdict" in
      DEVICE_UNREACHABLE)
        die "run doomed at ${waited}s — $verdict: $(device_state_advice "$verdict") (${state#*|})"
        ;;
      *)
        interference_streak=0
        ;;
    esac
    note "…still generating (${waited}s)"
  done

  [[ -n "$sentinel" && -f "$sentinel" ]] || die "no sentinel after ${timeout}s — autorun didn't write. Device state: $(probe_device_state 2>/dev/null || echo unknown). Diagnose live with: $0 console \"$spec\""

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
for e in r.get("interruptions") or []:
    print("  ⚠ interruption: %s at t=%.1fs" % (e.get("type"), (e.get("atMS") or 0) / 1000.0))
print("  device   :", r.get("deviceModel"), r.get("systemName"), r.get("systemVersion"))
PY

  note "── telemetry summary (engine decode / RTF / audioQC / RAM) ──"
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag" \
    ${label:+--label "$label"} >&2 || warn "summarizer found no engine rows (was QWENVOICE_DEBUG=1 honored?)"

  # Exit non-zero on a failed generation so CI/automation can gate on it.
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status")=="ok" else 1)' "$sentinel"
}

cmd_crashes() {
  local test_mode=0
  [[ "${1:-}" == "--test" ]] && test_mode=1
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

  note "── symbolication (optional xcsym when on PATH; otherwise Xcode Organizer) ──"
  local f
  for f in "$crash_dir"/*; do
    [[ -f "$f" ]] || continue
    if command -v xcsym >/dev/null 2>&1; then
      xcsym crash "$f" --dsym "$dsym" 2>&1 || warn "xcsym failed on $(basename "$f")"
    else
      warn "xcsym not on PATH — use Xcode Organizer, or consult \$axiom-tools before installing xcsym:"
      warn "  xcsym crash \"$f\" --dsym \"$dsym\""
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
  command -v xctrace >/dev/null 2>&1 \
    || die "xctrace not found — install Xcode and use Instruments for native profiling"

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
  note "analyze: open in Instruments, or use optional: xcprof analyze \"$trace\""

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

# preflight: physical-device reachability, signing, app, and dSYM.
# It fails fast with concrete remediation.
cmd_preflight() {
  local rc=0
  [[ $# -eq 0 ]] || die "preflight accepts no arguments"
  note "on-device preflight"

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
    if ! guard_device_state "$dev"; then rc=1; fi
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

  (( rc == 0 )) && note "preflight OK" || die "preflight not ready (see above)"
}

# Fail when ColdGeneration was skipped because the Speed model is missing on device.
_gate_generation_check() {
  local gate_dir="$1"
  [[ -d "$APP_PATH" ]] || cmd_install >/dev/null 2>&1 || true
  local run_id
  run_id="$(cmd_launch "custom:speed:Gate generation smoke." | tail -1)"
  local timeout="${QVOICE_IOS_BENCH_TIMEOUT:-300}"
  local dest="$gate_dir/.gen-diagnostics"
  rm -rf "$dest"
  local waited=0 sentinel=""
  local interference_streak=0
  while (( waited < timeout )); do
    sleep 10; waited=$((waited + 10))
    ( cmd_pull "$dest" ) >/dev/null 2>&1 || true
    sentinel="$(find "$dest" -name autorun-done.json -path "*/${run_id}/*" 2>/dev/null | head -1)"
    [[ -n "$sentinel" && -f "$sentinel" ]] && break
    # Fast-abort on interference (same policy as cmd_bench's poll loop).
    local state verdict
    state="$(probe_device_state 2>/dev/null || true)"
    verdict="${state%%|*}"
    case "$verdict" in
      DEVICE_UNREACHABLE)
        echo "aborted at ${waited}s — $verdict: $(device_state_advice "$verdict")"
        return 1
        ;;
      *) interference_streak=0 ;;
    esac
  done
  [[ -n "$sentinel" && -f "$sentinel" ]] || { echo "no autorun sentinel after ${timeout}s (device state: $(probe_device_state 2>/dev/null || echo unknown))"; return 1; }
  cp "$sentinel" "$gate_dir/generation-sentinel.json" 2>/dev/null || true
  python3 - "$sentinel" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"status={r.get('status')} mode={r.get('mode')} rtf={r.get('realtimeFactor')} wall={r.get('wallSeconds')}s error={r.get('error')}")
for e in r.get("interruptions") or []:
    print(f"interruption: {e.get('type')} at t={(e.get('atMS') or 0) / 1000.0:.1f}s")
sys.exit(0 if r.get("status") == "ok" else 1)
PY
}

cmd_gate() {
  local run_id="ios-gate-$(date +%Y%m%d-%H%M%S)"
  local gate_dir="$ROOT_DIR/build/ios/$run_id"
  local verdict="$gate_dir/verdict.txt"
  mkdir -p "$gate_dir"
  note "iOS device gate: project inputs"
  "$ROOT_DIR/scripts/check_project_inputs.sh" >"$gate_dir/inputs.log" 2>&1 \
    || { echo "project-inputs: FAIL" | tee "$verdict"; return 1; }
  echo "project-inputs: PASS" | tee "$verdict"
  note "iOS device gate: physical-device preflight"
  cmd_preflight >"$gate_dir/preflight.log" 2>&1 \
    || { echo "preflight: FAIL" | tee -a "$verdict"; return 1; }
  echo "preflight: PASS" | tee -a "$verdict"
  note "iOS device gate: headless generation"
  if [[ "${QVOICE_GATE_SKIP_GENERATION:-0}" == "1" ]]; then
    echo "generation: SKIPPED" | tee -a "$verdict"
  elif _gate_generation_check "$gate_dir" >"$gate_dir/generation.log" 2>&1; then
    echo "generation: PASS" | tee -a "$verdict"
  else
    echo "generation: FAIL" | tee -a "$verdict"; return 1
  fi
  note "iOS device gate: crashes"
  cmd_crashes >"$gate_dir/crashes.log" 2>&1 \
    || { echo "crashes: FAIL" | tee -a "$verdict"; return 1; }
  echo "crashes: PASS" | tee -a "$verdict"
  echo "GATE: PASS" | tee -a "$verdict"
  note "iOS gate PASS · $gate_dir"
}

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    doctor)  cmd_doctor "$@" ;;
    build)   cmd_build "$@" ;;
    install) cmd_install "$@" ;;
    launch)  cmd_launch "$@" ;;
    console) cmd_console "$@" ;;
    device-state) cmd_device_state "$@" ;;
    pull)    cmd_pull "$@" ;;
    bench)   cmd_bench "$@" ;;
    lang-bench) cmd_lang_bench "$@" ;;
    crashes) cmd_crashes "$@" ;;
    debug)   cmd_debug "$@" ;;
    logs)    cmd_logs "$@" ;;
    profile) cmd_profile "$@" ;;
    preflight) cmd_preflight "$@" ;;
    gate)      cmd_gate "$@" ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2 ;;
    *) die "unknown subcommand '$sub' (try: doctor|build|install|launch|console|device-state|pull|bench|lang-bench|crashes|debug|logs|profile|preflight|gate|help)" ;;
  esac
}

main "$@"
