#!/usr/bin/env bash
# Claude Code PreToolUse hook: the automatic T1 commit gate.
#
# Fired for every Bash tool call; exits instantly unless the command contains
# `git commit`. For commits it runs the quick project-inputs gate
# (QVOICE_GATES=quick ./scripts/check_project_inputs.sh) and blocks the commit
# on failure. A fingerprint of the current tree state is cached under
# build/scratch/gate-fingerprint (scratch-class output) so repeat commits on
# an already-validated tree are a no-op.
#
# Escape hatch (emergencies only): QVOICE_SKIP_COMMIT_GATE=1 skips the gate
# for that one invocation. CI never uses this hook; the full suite on GitHub
# remains the backstop for every push.

set -euo pipefail

payload="$(cat 2>/dev/null || true)"
command_text="$(printf '%s' "$payload" \
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    print("")' 2>/dev/null || true)"

case "$command_text" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

if [[ "${QVOICE_SKIP_COMMIT_GATE:-0}" == "1" ]]; then
  echo "commit gate: skipped once (QVOICE_SKIP_COMMIT_GATE=1)" >&2
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

marker_dir="build/scratch/gate-fingerprint"
marker="$marker_dir/last-pass"
log="$marker_dir/last-run.log"

# Conservative tree fingerprint: any commit, edit, or staging change since the
# last passing gate re-runs it. Repeat attempts on an identical tree are free.
fingerprint="$({
  git rev-parse HEAD 2>/dev/null
  git status --porcelain 2>/dev/null
  git diff --cached 2>/dev/null | shasum -a 256
} | shasum -a 256 | cut -d' ' -f1)"

if [[ -f "$marker" && "$(cat "$marker" 2>/dev/null)" == "$fingerprint" ]]; then
  exit 0
fi

mkdir -p "$marker_dir"
echo "commit gate: running QVOICE_GATES=quick ./scripts/check_project_inputs.sh …" >&2
if QVOICE_GATES=quick ./scripts/check_project_inputs.sh >"$log" 2>&1; then
  printf '%s\n' "$fingerprint" >"$marker"
  echo "commit gate: PASS" >&2
  exit 0
fi

echo "commit gate FAILED — last lines of $log:" >&2
tail -20 "$log" >&2 || true
echo "Fix the failure (or QVOICE_SKIP_COMMIT_GATE=1 to bypass once); the full CI suite still runs on push." >&2
exit 2
