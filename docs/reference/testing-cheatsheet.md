# Testing Cheatsheet

Copy-pasteable commands for the three testing layers. For when-to-run-what, see [`testing-overview.md`](testing-overview.md). For the AX-id vocabulary and standard skeletons, see [`ui-test-surface.md`](ui-test-surface.md).

## Preflight

```sh
[ -d build/Debug/Vocello.app ] || scripts/build.sh debug
scripts/uitest.sh smoke-check custom   # or design / clone
```

## iPhone 17 Pro device run

Docs: [`ios-shipping.md`](ios-shipping.md) (hub) · phased MLX proof: `scripts/ios_device_proof_matrix.sh --phase preflight`

```sh
scripts/ios_device.sh doctor
scripts/ios_device.sh start

# Drive the mirrored iPhone UI through Computer Use, then capture milestones.
scripts/ios_device.sh screenshot custom-complete
scripts/ios_device.sh pull
```

`doctor` writes the readiness gate result to `build/Debug/ios-device/runs/<run-id>/readiness.json`. Treat `GREEN` as real hardware testing/profiling readiness, `AMBER` as install/run-only readiness, and `RED` / `NO_DEVICE` as simulator-only fallback.

Real MLX generation on hardware still depends on Apple's increased-memory entitlement; without it, this workflow remains useful for UI, model delivery, extension transport, and diagnostics proof.

Debug-only memory guard probes:

```sh
scripts/ios_device.sh start --run-id guarded-probe --force-band guarded
scripts/ios_device.sh start --run-id critical-once-probe --force-critical-once
scripts/ios_device.sh start --run-id mlx-limit-probe --mlx-memory-limit-mb 2800 --mlx-cache-limit-mb 64
```

## One-shot Custom Voice smoke (~1 min)

```sh
# 1) Setup
ART=$(scripts/uitest.sh artifacts-dir)
(scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &); LOG_PID=$!
scripts/uitest.sh reset
scripts/uitest.sh prep

# 2) Front the app (user-computer-use MCP)
#    scripts/uitest.sh activate
#    get_screenshot → record image_width/image_height as IW × IH
#    screen-locate <ax-id> $IW $IH for click coords

# 3) Drive UI (user-computer-use MCP)
#    left_click sidebar_customVoice → left_click textInput_textEditor → type → key super+Return

# 4) Record T0 just before super+Return:
T0="$(/usr/bin/python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])')"

# 5) Verify
scripts/uitest.sh verify-generation custom \
    --artifacts-dir "$ART" --since "$T0" \
    --text "This is a Vocello smoke test. The quick brown fox jumps over the lazy dog."

# 6) Teardown
/usr/sbin/screencapture -x "$ART/post.png"
kill "$LOG_PID" 2>/dev/null || true
```

Substitute `design` or `clone` for `custom` to run the other smokes. See [`smoke-*.md`](.) for the per-mode deltas (different fixed inputs, screen check, extra steps before generate).

## Full bench matrix for one mode (~12 min)

```sh
ART=$(scripts/uitest.sh artifacts-dir); echo "$ART"
# Computer-use: scripts/uitest.sh activate + get_screenshot → record IW × IH

for variant in speed quality; do
  # 1a — fresh launch
  scripts/uitest.sh reset && scripts/uitest.sh prep && scripts/uitest.sh activate

  # 1b — nav + variant select + (clone) saved-voice bind
  #     Computer-use: click sidebar_<mode>, then variant button (3-fallback ladder)

  # 1c — initial T0
  python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0

  # 1d — three cold/medium samples
  for i in 1 2 3; do
    # Computer-use: left_click + type + key super+Return with medium prompt
    scripts/uitest.sh bench-step <mode> "$variant" cold medium --artifacts-dir "$ART" --timeout 180
    # (between cold samples — quit/reset/prep/relaunch and re-do 1b)
  done

  # 1e — warm samples
  for bucket in short medium long; do
    for i in 1 2 3; do
      # Computer-use: key super+a → BackSpace → type bucket prompt → key super+Return
      scripts/uitest.sh bench-step <mode> "$variant" warm "$bucket" --artifacts-dir "$ART"
    done
  done
done

scripts/uitest.sh bench-summarize "$ART"
scripts/uitest.sh bench-compare "$ART"   # exits 1 on ±15 % drift
```

Promote new baseline only when intentional:

```sh
scripts/uitest.sh bench-update-baselines
git diff docs/reference/benchmark-baselines.json
```

## Recovery (when computer-use clicks miss)

```sh
scripts/uitest.sh activate                  # bring Vocello to front
```
```text
get_screenshot  # re-record IW × IH; the window may have moved; click twice if first click only focused
```

Common causes: Notification Center stole focus, or another app got fronted. Re-fronting + fresh screenshot always recovers. See [`computer-use-mcp.md`](computer-use-mcp.md).

## Inspect a generation after the fact

```sh
# Newest row + audio path
scripts/uitest.sh db "SELECT id, mode, text, audioPath, duration FROM generations ORDER BY createdAt DESC LIMIT 1"

# All Custom Voice WAVs from this Debug session
ls -lt "$HOME/Library/Application Support/QwenVoice-Debug/outputs/CustomVoice/" | head

# Tail the signpost log live
scripts/uitest.sh logs
```
