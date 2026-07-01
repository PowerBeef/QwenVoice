# Shared helper: export named PNG attachments (e.g. review-*.png) from an .xcresult
# into a destination directory with clean names. Robust against xcodebuild not
# propagating MAC_TEST_SCREENSHOT_DIR / UI_TEST_SCREENSHOT_DIR into the test runner
# (env needs the TEST_RUNNER_ prefix, and on-device iOS runners can't write Mac paths
# at all) — the .xcresult attachments always exist.
#
# usage: export_xcresult_shots <xcresult-path> <dest-dir> <name-prefix>
# Copies attachments whose suggested name starts with <name-prefix> to
# <dest-dir>/<clean-name>.png where clean-name strips the _N_UUID suffix XCTest adds.

# shellcheck shell=bash

export_xcresult_shots() {
  local xcresult="$1" dest="$2" prefix="$3"
  [[ -d "$xcresult" ]] || return 1
  mkdir -p "$dest"
  local tmp; tmp="$(mktemp -d)"
  if ! xcrun xcresulttool export attachments --path "$xcresult" --output-path "$tmp" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  python3 - "$tmp" "$dest" "$prefix" <<'PY'
import json, re, shutil, sys
from pathlib import Path

tmp, dest, prefix = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
manifest = tmp / "manifest.json"
if not manifest.exists():
    sys.exit(1)
count = 0
for item in json.loads(manifest.read_text()):
    for att in item.get("attachments", []):
        name = att.get("suggestedHumanReadableName") or ""
        exported = att.get("exportedFileName") or ""
        if not name.startswith(prefix) or not exported.lower().endswith(".png"):
            continue
        # "review-custom-ready_0_D8FE0EA6-....png" -> "review-custom-ready.png"
        clean = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.png$)", "", name)
        src = tmp / exported
        if src.exists():
            shutil.copyfile(src, dest / clean)
            count += 1
print(count)
sys.exit(0 if count else 1)
PY
  local st=$?
  rm -rf "$tmp"
  return $st
}
