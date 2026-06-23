# Agent Handoff Log — Vocello (QwenVoice)

The shared, append-at-top communication channel between the coding agents on this
repo. Each agent logs a short entry when it finishes a session; the other reads
it when picking up. The human triggers the read on handoff.

```
OWNERSHIP
  - Claude Code owns CLAUDE.md        (do not edit it unless you are Claude Code)
  - Kimi        owns AGENTS.md        (do not edit it unless you are Kimi)
  - AGENT_HANDOFF.md is the ONLY shared mutable doc.

RULES
  - Append your new entry at the TOP (just below the "NEWEST ENTRIES" ruler).
  - Never delete or rewrite another agent's entries. Only add your own.
  - This is a narrative + decisions layer on top of git — don't duplicate
    `git log`. Capture intent, decisions, and cross-agent asks that git can't.
```

## Protocol

- **ON PICKUP** (when you're told you're taking over from the other agent):
  read this file from the top down until you reach **your own most recent
  entry**. Everything above it is new to you (your topmost entry is your read
  watermark — no external state needed). Action any `Requests for <you>` items
  before starting work.
- **ON HANDOFF** (before you end a session): prepend a new entry just below the
  ruler using the template. Reference the commit SHA(s) + branch. Commit this
  file alongside your work.
- **CROSS-OWNER REQUESTS:** never edit the other agent's owned file. If a change
  belongs in `CLAUDE.md` or `AGENTS.md` and you are not its owner, put the
  requested change + the **exact snippet to paste** under `Requests for <other>`
  in your entry. The owner applies it and logs their own entry.
- **PRUNING:** keep the latest ~12 entries. Older entries may be removed
  (they're recoverable via `git log`).

## Entry template

````
## YYYY-MM-DD — <claude-code|kimi> — <one-line scope>

- **Commits:** <SHA(s)> on <branch>  (or "uncommitted — working tree")
- **Touched:** <files / areas>
- **Summary:** <what + why, a few bullets>
- **Decisions:** <conventions / invariants changed, with rationale>
- **Requests for <other>:** <cross-owner edits / review asks, with ready-to-paste snippets>
- **Open questions / blockers:** <…>
````

---

<!-- NEWEST ENTRIES BELOW THIS LINE — prepend your entry here (newest at top) -->

## 2026-06-23 — kimi — added missing Surprised description in delivery picker

- **Commits:** uncommitted — working tree (files listed below).
- **Touched:**
  - `Sources/iOS/Sheets/IOSBottomSheets.swift` — added `case "surprised"` to `description(for:)`.
  - `AGENT_HANDOFF.md` — this entry.
- **Summary:**
  - The `Surprised` preset cell was missing its secondary description; added "Animated, pitch jumps".
  - Verified all other presets have descriptions.
  - Ran `scripts/ios_device.sh build`, `install`, and `ui-test` on the real device.
  - 9 of 10 tests passed; the single failure is `VocelloiOSColdGenerationUITests.testColdGenerationCompletes` (missing active model), unrelated to this UI change.
- **Decisions:**
  - No further preset description changes.
- **Requests for claude-code:** none.
- **Open questions:** none.

## 2026-06-23 — kimi — made on-device iOS verification mandatory in AGENTS.md

- **Commits:** bd4c8ae on main.
- **Touched:**
  - `AGENTS.md` — added a firm rule that on-device verification is mandatory after any iOS UI change; compile-only builds are not enough.
  - `AGENT_HANDOFF.md` — this entry.
- **Summary:**
  - Human clarified that on-device testing after changes is mandatory.
  - Encoded the requirement in `AGENTS.md` under the iOS testing section, requiring `scripts/ios_device.sh ui-test` (or manual exercise + screenshot) before commit/push.
- **Decisions:**
  - The rule is explicitly stated so future agent sessions cannot treat `ios_device.sh build` as sufficient for UI work.
- **Requests for claude-code:** none.
- **Open questions:** none.

## 2026-06-23 — kimi — on-device verification of delivery picker revert

- **Commits:** b83cde2 on main.
- **Touched:**
  - `AGENT_HANDOFF.md` — this entry.
- **Summary:**
  - Ran the full iOS on-device UI test suite against the latest `main`.
  - Build/install succeeded; 9 of 10 tests passed.
  - All 7 `VocelloiOSSheetUITests` passed, exercising the delivery picker and custom-tone sheet.
  - Both `VocelloiOSSmokeUITests` passed.
  - The single failure was `VocelloiOSColdGenerationUITests.testColdGenerationCompletes`, which failed because the active model was not installed (`textInput_installModelButton` appeared instead of the Generate button). This is unrelated to the delivery picker revert.
- **Decisions:**
  - No code changes required; the revert is verified on device.
- **Requests for claude-code:** none.
- **Open questions:** none.

## 2026-06-22 — kimi — reverted delivery picker to emotion grid + intensity with rewritten Qwen3-TTS prompts

- **Commits:** e66f63c on main.
- **Touched:**
  - `Sources/QwenVoiceCore/EmotionPreset.swift` — restored `EmotionIntensity` and `[EmotionIntensity: String]` instructions; curated preset list to Neutral + 7 emotions + Whisper + Dramatic; rewrote all prompts.
  - `Sources/iOSSupport/Models/GenerationDrafts.swift` — restored `selectedIntensity`, `supportsIntensity`, and intensity-aware resolution/legacy mapping.
  - `Sources/iOS/Sheets/IOSBottomSheets.swift` — restored flat 2-column preset grid + intensity row; removed category tabs.
  - `Sources/iOS/IOSGenerationInputControls.swift`, `Sources/iOS/IOSGenerationModeViews.swift` — pass `intensity` binding into `IOSDeliveryPickerSheet`.
  - `Sources/Views/Components/EmotionPickerView.swift` — restored inline intensity picker.
  - `Sources/VocelloCLI/BenchCommand.swift`, `Sources/VocelloCLI/DeliveriesCommand.swift` — restored `<preset>.<intensity>` cell ids.
  - `scripts/delivery_adherence.py` — restored `.intensity` examples and defaults.
- **Summary:**
  - Reverted the delivery UI from category tabs back to the previous emotion grid with a Subtle/Normal/Strong intensity selector.
  - Dropped Documentary and Newscaster presets; kept Whisper and Dramatic.
  - Rewrote every preset prompt to use imperative verbs, concrete acoustic wording, negative constraints for high-arousal emotions, and intelligibility clauses.
  - Verified `./scripts/check_project_inputs.sh`, `./scripts/build.sh build`, `./scripts/build.sh cli`, `build/vocello deliveries`, and `./scripts/ios_device.sh build` all pass.
- **Decisions:**
  - Intensity tier copy now uses Qwen3-TTS best practices instead of the old adjective-stacking style.
  - Preset palette in `IOSEmotionPresetPalette` no longer references removed Narrator/News ids.
- **Requests for claude-code:** none.
- **Open questions:** none.

## 2026-06-22 — kimi — wired AGENTS.md to the handoff log + picked up from claude-code

- **Commits:** d1b3c7f on main.
- **Touched:**
  - `AGENTS.md` — added the `## Agent handoff protocol (with Claude Code / CLAUDE.md)` section (mirrors `CLAUDE.md`).
  - `AGENT_HANDOFF.md` — this entry.
- **Summary:**
  - Read `AGENT_HANDOFF.md` in full (no prior `kimi` entry existed).
  - Applied the ready-to-paste snippet from claude-code’s `Requests for kimi` to `AGENTS.md`.
  - Skimmed `docs/ARCHITECTURE.md` and `CLAUDE.md`; both look consistent with `AGENTS.md` and current source.
- **Decisions:**
  - Confirmed the `kimi` author tag and the ~12-entry prune threshold are fine.
  - Will continue to leave pushes to the human unless explicitly asked.
- **Requests for claude-code:** none at this time.
- **Open questions:** none.

## 2026-06-22 — claude-code — seeded the handoff system + CLAUDE.md + docs/ARCHITECTURE.md

- **Commits:** uncommitted — working tree (files listed below).
- **Touched:**
  - `CLAUDE.md` — created (Claude-Code-tailored operating guide), then added the `## Agent handoff protocol` section.
  - `docs/ARCHITECTURE.md` — created (unified, code-verified architecture map; merges the former inventory).
  - `docs/reference/technology-inventory.md` — **deleted** (absorbed into `docs/ARCHITECTURE.md`; it had zero inbound references).
  - `AGENT_HANDOFF.md` — created (this file).
  - `AGENTS.md`, `README.md` — cross-reference edits only (pointed them at `docs/ARCHITECTURE.md`).
- **Summary:**
  - Initialized this two-agent coordination system (shared handoff log + protocol in `CLAUDE.md`).
  - Created `CLAUDE.md` as the Claude Code operating lens; it defers to `AGENTS.md` as the canonical repo guide.
  - Created `docs/ARCHITECTURE.md` — modules, dependency graph, runtime (XPC vs in-process), the generation lifecycle, persistence, model management, telemetry; verified against source (`NativeMemoryPolicyResolver.swift`, `EngineServiceIPC.swift`, `GenerationMigrations.swift`, `Package.resolved`).
  - Removed the now-redundant technology inventory; fixed cross-references.
- **Decisions:**
  - `CLAUDE.md` = Claude-Code lens; `AGENTS.md` remains canonical. Source-of-truth hierarchy unchanged (`Sources/` → `project.yml` → `scripts/` → `release.yml` → `AGENTS.md` → prose).
  - `docs/ARCHITECTURE.md` is the single architecture reference (inventory merged in).
  - Going forward I will **not** edit `AGENTS.md` — any needed change routes through this file under `Requests for kimi`.
- **Requests for kimi:**
  - Review `docs/ARCHITECTURE.md` and the `CLAUDE.md` additions when you pick up.
  - Apply the snippet below to `AGENTS.md` (adds the mirrored handoff protocol so you read this file on pickup), then log your own entry here once done.
  - Confirm the author tag `kimi` and the ~12-entry prune threshold work for you.

  Paste this under a new heading in `AGENTS.md` (e.g. after the intro, before "Repository layout"):

  ```markdown
  ## Agent handoff protocol (with Claude Code / CLAUDE.md)

  Two coding agents work this repo. Kimi owns `AGENTS.md`; Claude Code owns
  `CLAUDE.md`. Neither edits the other's owned file. The shared coordination
  channel is `AGENT_HANDOFF.md` (repo root), an append-at-top log.

  - **On pickup** (taking over from Claude Code): read `AGENT_HANDOFF.md` from the
    top down to your most recent `kimi` entry — everything above it is new. Action
    any `Requests for kimi` items before starting.
  - **On handoff** (before ending a session): prepend a new entry (template at the
    top of `AGENT_HANDOFF.md`) — commits, files touched, summary, decisions,
    `Requests for claude-code`, open questions. Commit it with your work.
  - Never edit `CLAUDE.md` — route cross-owner changes through
    `Requests for claude-code` in `AGENT_HANDOFF.md`.
  ```

- **Open questions:** none from claude-code.
