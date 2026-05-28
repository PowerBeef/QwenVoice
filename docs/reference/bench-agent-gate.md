# Agent bench gate (6-cell review)

Minimal timing gate for targeted backend reviews (streaming regression, vendor changes, memory policy). **Agent-executed** — no shell script drives the UI. Use [`computer-use-mcp.md`](computer-use-mcp.md) for MCP invocation.

## Matrix

| Mode | Cold/warm | Prompt | Variant | n |
|---|---|---|---|---|
| custom | cold | medium | speed | 1 |
| custom | warm | medium | speed | 1 |
| design | cold | medium | speed | 1 |
| design | warm | medium | speed | 1 |
| clone | cold | medium | speed | 1 |
| clone | warm | medium | speed | 1 |

Fixed medium prompt: `This is a Vocello smoke test. The quick brown fox jumps over the lazy dog.`

Voice Design description (cold/warm): `A calm, deep documentary narrator with a measured pace.`

Voice Cloning: requires `UITestRef` saved voice (`scripts/uitest.sh smoke-check clone`).

## Ritual

### 1. Precondition

```sh
[ -d build/Debug/Vocello.app ] || ./scripts/build.sh debug
./scripts/uitest.sh smoke-check custom
./scripts/uitest.sh smoke-check design
./scripts/uitest.sh smoke-check clone
```

### 2. Setup

```sh
ART=$(./scripts/uitest.sh artifacts-dir)
echo "$ART"
(./scripts/uitest.sh logs > "$ART/log.txt" 2>&1 &)
LOG_PID=$!
```

### 3. Per cell

For each `(mode, coldwarm)` pair:

1. **Cold only:** `./scripts/uitest.sh reset && ./scripts/uitest.sh prep`
2. `./scripts/uitest.sh activate`
3. `mcp__computer-use__screenshot` (locate elements by sight)
4. Drive UI per mode (see per-mode bench runbooks + [`ui-test-surface.md`](ui-test-surface.md)):
   - Navigate: click the `sidebar_<mode>` row by sight
   - Select speed variant if needed (click Speed button by sight)
   - Voice Design: fill description field
   - Voice Cloning: pick `UITestRef` (keyboard picker pattern)
   - Click the script field by sight → `type` medium prompt → `key cmd+Return`
5. Record sample:
   ```sh
   ./scripts/uitest.sh bench-step <mode> speed <cold|warm> medium \
       --artifacts-dir "$ART" --timeout 180
   ```

Initialize T0 before the first cell:

```sh
python3 -c "import datetime as dt; d=dt.datetime.now(); print(d.strftime('%Y-%m-%d %H:%M:%S.')+d.strftime('%f')[:3])" > /tmp/uitest_bench_t0
```

### 4. Summarize + compare

```sh
./scripts/uitest.sh bench-summarize "$ART"
./scripts/uitest.sh bench-compare "$ART"
kill "$LOG_PID" 2>/dev/null || true
```

Pass criteria: `bench-compare` within ±15% on `ms_engine_start_to_final` and `rtf` (see [`ui-test-surface.md`](ui-test-surface.md) for reading paired signals).

### 5. Encode-drop check

```sh
grep -c encode_dropped \
  "$HOME/Library/Application Support/QwenVoice-Debug/diagnostics/engine-service/native-events.jsonl" \
  2>/dev/null || echo "native-events.jsonl not present — run at least one successful generation first"
```

Expect **zero** `engine_service_encode_dropped` events after streaming fixes.

## Do not use

- `scratch/run-mlx-review-bench-gate.sh` — removed; osascript automation failed to populate the SwiftUI editor.
- `user-automation-mcp` — types into whatever window has focus.
- osascript `keystroke` / `click at` — same focus risk; not for Vocello UI.
- Drive with the native `computer-use` MCP (`mcp__computer-use__*`) + vision; see [`computer-use-mcp.md`](computer-use-mcp.md).
