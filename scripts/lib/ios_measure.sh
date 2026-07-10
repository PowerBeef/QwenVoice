#!/usr/bin/env bash
# Drive-agnostic measurement shell for iOS agent smokes (mirroir exploratory QA).
#
# Mirrors the macOS scripts/macos_agent_ui.sh contract: UI driving is decoupled from
# verification — pass/fail comes from pulled engine telemetry + audioQC, not how the tap happened.
#
# Usage (via scripts/ios_device.sh measure-*):
#   measure-prep [--run-id ID] [--force-cold 0|1]
#   measure-now
#   measure-wait --run-id ID --since ISO8601 [--timeout N] [--pull-root DIR]
#   measure-verify --run-id ID --since ISO8601 [--artifacts-dir DIR] [--timeout N]
#   measure-artifacts-dir [--run-id ID]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

ios_measure_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ios_measure_prep() {
  local run_id="" force_cold=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="${2:-}"; shift 2 ;;
      --run-id=*) run_id="${1#*=}"; shift ;;
      --force-cold) force_cold="${2:-1}"; shift 2 ;;
      --force-cold=*) force_cold="${1#*=}"; shift ;;
      *) die "unknown measure-prep arg: $1" ;;
    esac
  done
  run_id="${run_id:-ios-smoke-$(date +%Y%m%d-%H%M%S)}"
  "$ROOT_DIR/scripts/ios_device.sh" vision-launch --run-id "$run_id" --force-cold "$force_cold"
  echo "$run_id"
}

ios_measure_wait() {
  "$ROOT_DIR/scripts/lib/ios_vision_bench_wait.sh" wait "$@"
}

ios_measure_artifacts_dir() {
  local run_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="${2:-}"; shift 2 ;;
      --run-id=*) run_id="${1#*=}"; shift ;;
      *) die "unknown measure-artifacts-dir arg: $1" ;;
    esac
  done
  run_id="${run_id:-ios-smoke-$(date +%Y%m%d-%H%M%S)}"
  local dir="$ROOT_DIR/build/ios/measure-$run_id"
  mkdir -p "$dir"
  echo "$dir"
}

ios_measure_verify() {
  local run_id="" since="" timeout=240 artifacts_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) run_id="${2:-}"; shift 2 ;;
      --run-id=*) run_id="${1#*=}"; shift ;;
      --since) since="${2:-}"; shift 2 ;;
      --since=*) since="${1#*=}"; shift ;;
      --timeout) timeout="${2:-240}"; shift 2 ;;
      --timeout=*) timeout="${1#*=}"; shift ;;
      --artifacts-dir) artifacts_dir="${2:-}"; shift 2 ;;
      --artifacts-dir=*) artifacts_dir="${1#*=}"; shift ;;
      *) die "unknown measure-verify arg: $1" ;;
    esac
  done
  [[ -n "$run_id" ]] || die "measure-verify requires --run-id"
  [[ -n "$since" ]] || die "measure-verify requires --since (capture before Generate: measure-now)"

  if [[ -z "$artifacts_dir" ]]; then
    artifacts_dir="$(ios_measure_artifacts_dir --run-id "$run_id")"
  else
    mkdir -p "$artifacts_dir"
  fi

  local wait_out=""
  if ! wait_out="$(ios_measure_wait --run-id "$run_id" --since "$since" --timeout "$timeout" 2>&1)"; then
    printf '%s\n' "$wait_out" >&2
    RUN_ID="$run_id" SINCE="$since" ART="$artifacts_dir" python3 - <<'PY'
import json, os, datetime as dt
art = os.environ["ART"]
out = {
    "pass": False,
    "runID": os.environ["RUN_ID"],
    "since": os.environ["SINCE"],
    "reason": "measure-wait failed or timed out",
    "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
open(f"{art}/result.json", "w").write(json.dumps(out, indent=2) + "\n")
PY
    die "measure-verify FAIL — see $artifacts_dir/result.json"
  fi
  note "measure-wait: $wait_out"

  local pull_root="$ROOT_DIR/build/ios-diagnostics"
  "$ROOT_DIR/scripts/ios_device.sh" pull "$pull_root" >/dev/null 2>&1 || true
  local engine_jsonl
  engine_jsonl="$(find "$pull_root" -path '*/engine/generations.jsonl' 2>/dev/null | head -1)"
  [[ -n "$engine_jsonl" && -f "$engine_jsonl" ]] || die "measure-verify: no engine/generations.jsonl after pull"

  RUN_ID="$run_id" SINCE="$since" ENGINE="$engine_jsonl" ART="$artifacts_dir" WAIT="$wait_out" \
    python3 - <<'PY'
import json, os, datetime as dt, shutil, sys

run_id = os.environ["RUN_ID"]
since = os.environ["SINCE"]
engine = os.environ["ENGINE"]
art = os.environ["ART"]
wait_line = os.environ.get("WAIT", "")

rows = []
with open(engine) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        notes = row.get("notes") or {}
        if notes.get("benchRunID") != run_id:
            continue
        rows.append(row)

if not rows:
    out = {
        "pass": False, "runID": run_id, "since": since,
        "reason": f"no telemetry rows for benchRunID={run_id}",
        "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    open(f"{art}/result.json", "w").write(json.dumps(out, indent=2) + "\n")
    print(f"FAIL: no rows for runID={run_id}", file=sys.stderr)
    sys.exit(1)

row = rows[-1]
qc = row.get("audioQC") or {}
verdict = qc.get("verdict", "pass")
if isinstance(verdict, str) and verdict.startswith("fail"):
    out = {
        "pass": False, "runID": run_id, "since": since,
        "generationID": row.get("generationID"), "mode": row.get("mode"),
        "audioQC": verdict, "reason": "audioQC failed",
        "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    open(f"{art}/result.json", "w").write(json.dumps(out, indent=2) + "\n")
    print(f"FAIL: audioQC={verdict}", file=sys.stderr)
    sys.exit(1)

shutil.copy2(engine, f"{art}/generations.jsonl")
out = {
    "pass": True,
    "runID": run_id,
    "since": since,
    "generationID": row.get("generationID"),
    "mode": row.get("mode"),
    "realtimeFactor": row.get("realtimeFactor"),
    "wallSeconds": row.get("wallSeconds"),
    "audioQC": verdict,
    "wait": wait_line.strip(),
    "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
open(f"{art}/result.json", "w").write(json.dumps(out, indent=2) + "\n")
print(f"ok: pass=true runID={run_id} mode={row.get('mode')} id={row.get('generationID')} qc={verdict}")
PY
}
