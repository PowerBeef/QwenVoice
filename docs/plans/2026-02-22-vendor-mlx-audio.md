# Vendor mlx-audio Wheel Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the `mlx-audio @ git+https://...` entry in `requirements.txt` with a pre-built wheel committed to the repo, so first-boot venv creation and release builds never depend on GitHub being available.

**Architecture:** Build a wheel from the pinned commit once, store it in `QwenVoice/Resources/vendor/`. Pass `--find-links <vendor-dir>` to every pip invocation — both in `PythonEnvironmentManager.swift` (dev/first-boot) and `bundle_python.sh` (release builds). pip resolves mlx-audio from the local wheel; all other packages continue to come from PyPI.

**Tech Stack:** Swift (PythonEnvironmentManager), bash (bundle_python.sh), pip wheel building.

---

### Task 1: Build the mlx-audio wheel from the pinned commit

**Files:**
- Create: `QwenVoice/QwenVoice/Resources/vendor/` (directory)

**Step 1: Build the wheel**

```bash
pip3 wheel \
  "mlx-audio @ git+https://github.com/Blaizzy/mlx-audio.git@9349644ccbd62eb10900852228f7b952c566def3" \
  --no-deps \
  -w /tmp/mlx_audio_wheel/
```

`--no-deps` builds only mlx-audio itself (its dependencies are already in requirements.txt).

Expected output ends with:
```
Successfully built mlx-audio
Stored in directory: /tmp/mlx_audio_wheel/
```

**Step 2: Note the exact wheel filename**

```bash
ls /tmp/mlx_audio_wheel/
```

The filename will be something like `mlx_audio-0.X.Y-py3-none-any.whl`.
Note the version number (`0.X.Y`) — you'll need it in Task 2.

**Step 3: Create vendor directory and copy wheel**

```bash
mkdir -p /Users/patricedery/Coding_Projects/QwenVoice/QwenVoice/QwenVoice/Resources/vendor
cp /tmp/mlx_audio_wheel/mlx_audio-*.whl \
   /Users/patricedery/Coding_Projects/QwenVoice/QwenVoice/QwenVoice/Resources/vendor/
```

**Step 4: Verify**

```bash
ls /Users/patricedery/Coding_Projects/QwenVoice/QwenVoice/QwenVoice/Resources/vendor/
```

Expected: one `.whl` file listed.

---

### Task 2: Update requirements.txt

**Files:**
- Modify: `QwenVoice/QwenVoice/Resources/requirements.txt:27`

**Step 1: Replace the git URL line**

Open `QwenVoice/QwenVoice/Resources/requirements.txt`. Line 27 currently reads:
```
mlx-audio @ git+https://github.com/Blaizzy/mlx-audio.git@9349644ccbd62eb10900852228f7b952c566def3
```

Replace it with a plain versioned specifier using the version noted in Task 1:
```
mlx-audio==0.X.Y
```

(Use the actual version from the wheel filename — e.g. if wheel is `mlx_audio-0.3.7-py3-none-any.whl`, write `mlx-audio==0.3.7`.)

**Step 2: Verify the file looks correct**

The file should still have 61 non-comment, non-blank lines. Line 27 is the only change.

---

### Task 3: Update PythonEnvironmentManager.swift

**Files:**
- Modify: `QwenVoice/QwenVoice/Services/PythonEnvironmentManager.swift`

This file manages the first-boot venv setup. We need to:
- Add a `resolveVendorDir()` helper (mirrors the existing `resolveRequirementsPath()` pattern)
- Pass `--find-links <vendorDir>` to every pip invocation

**Step 1: Add `resolveVendorDir()` helper**

Find the `resolveRequirementsPath()` function (around line 411). Directly after it, add:

```swift
private func resolveVendorDir() -> String? {
    // Production bundle
    if let resourceURL = Bundle.main.resourceURL {
        let bundledVendor = resourceURL.appendingPathComponent("vendor").path
        if FileManager.default.fileExists(atPath: bundledVendor) {
            return bundledVendor
        }
    }
    // Development: relative to this source file
    let devPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/vendor").path
    if FileManager.default.fileExists(atPath: devPath) {
        return devPath
    }
    return nil
}
```

**Step 2: Resolve vendorDir early in `runSetup()`**

Find the line in `runSetup()` that reads:
```swift
// 2. Check existing venv with valid marker
```

Immediately before that comment, add:
```swift
let vendorDir = resolveVendorDir()
```

**Step 3: Thread vendorDir through the updatingDependencies pip call**

Find the `runPipInstallWithRetry` call inside the `// 2b. Venv exists but marker is stale` block (around line 110). It currently reads:
```swift
try await runPipInstallWithRetry(
    pipPath: pipPath,
    requirementsPath: reqPath,
    totalPackages: totalPackages
)
```

Replace with:
```swift
try await runPipInstallWithRetry(
    pipPath: pipPath,
    requirementsPath: reqPath,
    totalPackages: totalPackages,
    vendorDir: vendorDir
)
```

**Step 4: Thread vendorDir through `installDependencies`**

Find the call to `installDependencies` at the bottom of `runSetup()`:
```swift
await installDependencies(venvPython: venvPython, requirementsPath: requirementsPath)
```

Replace with:
```swift
await installDependencies(venvPython: venvPython, requirementsPath: requirementsPath, vendorDir: vendorDir)
```

**Step 5: Update `installDependencies` signature and pip call**

Find `private func installDependencies(venvPython: String, requirementsPath: String) async`. Change its signature to:
```swift
private func installDependencies(venvPython: String, requirementsPath: String, vendorDir: String?) async
```

Inside it, find the `runPipInstallWithRetry` call and add `vendorDir`:
```swift
try await runPipInstallWithRetry(
    pipPath: pipPath,
    requirementsPath: requirementsPath,
    totalPackages: totalPackages,
    vendorDir: vendorDir
)
```

**Step 6: Update `runPipInstallWithRetry` signature and call**

Find `private func runPipInstallWithRetry(pipPath: String, requirementsPath: String, totalPackages: Int) async throws`. Change to:
```swift
private func runPipInstallWithRetry(pipPath: String, requirementsPath: String, totalPackages: Int, vendorDir: String?) async throws
```

Inside it, update the `runPipInstall` call:
```swift
try await runPipInstall(
    pipPath: pipPath,
    requirementsPath: requirementsPath,
    totalPackages: totalPackages,
    vendorDir: vendorDir
)
```

**Step 7: Update `runPipInstall` signature and arguments**

Find `private func runPipInstall(pipPath: String, requirementsPath: String, totalPackages: Int) async throws`. Change to:
```swift
private func runPipInstall(pipPath: String, requirementsPath: String, totalPackages: Int, vendorDir: String?) async throws
```

Inside `runPipInstall`, find where `proc.arguments` is set:
```swift
proc.arguments = ["install", "--progress-bar", "off", "-r", requirementsPath]
```

Replace with:
```swift
var pipArgs = ["install", "--progress-bar", "off"]
if let vendorDir {
    pipArgs += ["--find-links", vendorDir]
}
pipArgs += ["-r", requirementsPath]
proc.arguments = pipArgs
```

**Step 8: Verify the build compiles**

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice/QwenVoice && \
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

If it fails, read the full error output (`| tail -20`) and fix any type mismatches.

---

### Task 4: Update bundle_python.sh

**Files:**
- Modify: `QwenVoice/scripts/bundle_python.sh`

**Step 1: Add VENDOR_DIR variable**

Find this line (around line 9):
```bash
REQUIREMENTS="$PROJECT_DIR/../Qwen-Voice/requirements.txt"
```

After it, add:
```bash
VENDOR_DIR="$RESOURCES_DIR/vendor"
```

**Step 2: Add `--find-links` to pip install**

Find the pip install line (around line 70):
```bash
"$PYTHON_BUNDLE/bin/python3" -m pip install --quiet -r "$REQUIREMENTS"
```

Replace with:
```bash
"$PYTHON_BUNDLE/bin/python3" -m pip install --quiet --find-links "$VENDOR_DIR" -r "$REQUIREMENTS"
```

**Step 3: Verify the script is syntactically correct**

```bash
bash -n /Users/patricedery/Coding_Projects/QwenVoice/QwenVoice/scripts/bundle_python.sh && echo "OK"
```

Expected: `OK`

---

### Task 5: Clean install smoke test

**Step 1: Kill any running instance**

```bash
pkill -f "Qwen Voice" || true
```

**Step 2: Wipe app state**

```bash
rm -rf ~/Library/Application\ Support/QwenVoice/
defaults delete com.qwenvoice.app 2>/dev/null || true
rm -f ~/Library/Preferences/com.qwenvoice.app.plist
```

**Step 3: Build fresh debug app**

```bash
cd /Users/patricedery/Coding_Projects/QwenVoice/QwenVoice && \
xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 4: Launch the app**

```bash
open "/Users/patricedery/Library/Developer/Xcode/DerivedData/QwenVoice-grkcmlqmprdmwtefkdtaqqrmobaj/Build/Products/Debug/Qwen Voice.app"
```

If the path above fails (DerivedData hash differs), use:
```bash
open "$(xcodebuild -project QwenVoice.xcodeproj -scheme QwenVoice -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}')/Qwen Voice.app"
```

**Step 5: Observe setup flow**

The app should display SetupView and progress through all phases ending with a transition to ContentView. The mlx-audio install phase should complete without any network request to GitHub (it installs from the bundled wheel).

**Step 6: Confirm mlx-audio was installed from vendor**

After setup completes, inspect the installed package metadata:
```bash
cat ~/Library/Application\ Support/QwenVoice/python/lib/python3*/site-packages/mlx_audio-*.dist-info/METADATA | head -5
```

Expected: shows `Version: 0.X.Y` matching the wheel version from Task 1.
