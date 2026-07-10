# iOS agent UI tour — living reference

> **Purpose:** Human-guided map of the Vocello **iPhone** UI for **agent-driven** exploratory QA
> via **mirroir-mcp** (iPhone Mirroring). Updated incrementally as the product owner walks through
> the app.
>
> **Not a gate doc.** Pre-merge truth stays `scripts/ios_device.sh gate` + XCUITest identifiers in
> [`ui-test-surface.md`](ui-test-surface.md). For identifier-level test authoring see
> [`ios-app-guide.md`](ios-app-guide.md).
>
> **Driving stack (primary):** mirroir **`describe_screen`** → **`tap`** / **`type_text`** /
> **`measure`** (window-relative coords). Preflight:
> [`scripts/ios_mirroir_preflight.sh`](../../scripts/ios_mirroir_preflight.sh). App context:
> [`.mirroir-mcp/skills/apps/Vocello/APP.md`](../../.mirroir-mcp/skills/apps/Vocello/APP.md).
>
> **Fallback (legacy):** if `describe_screen` capture fails, observe with `ios_device.sh shot` and
> optional Peekaboo global clicks via [`ios_vision_bridge.sh`](../../scripts/lib/ios_vision_bridge.sh)
> — higher coord error; see [Appendix B](#appendix-b--mirroir-agent-driving-loop).

**Status:** **Phase 1 complete** (owner-guided tour + quiz, 2026-07-04). Agent-ready for
exploratory UI smokes, debugging, and bench **procedure** on the paired device. Remaining gaps are
optional only (engine lifecycle toasts) — not blockers for Custom/Clone smokes with saved voices.

**Test device:** Owner’s **iPhone 17 Pro** (fixed — no device variance in agent sessions).

| Section | Status |
| --- | --- |
| Navigation hierarchy | Documented |
| Studio — mode selector | Documented |
| Studio — Custom Voice composer | Documented |
| Studio — Voice Design | Documented |
| Studio — Voice Cloning | Documented |
| Voices tab | Documented |
| History tab | Documented |
| Settings tab | Documented |
| Sheets / overlays | Documented (§9) |

### Agent readiness (post-quiz)

| Capability | Ready? | Notes |
| --- | --- | --- |
| **Custom generate smoke** | Yes | Default screen; Aiden + NE + AU; script → Generate |
| **Design / Clone smokes** | Yes | Brief + script; pick **saved** reference (not record via mirror) |
| **Model prep in Settings** | Yes | Install **one model at a time** — simultaneous downloads **not** supported on iOS |
| **Deterministic verification** | Yes | History row, duration, transcript, playable audio |
| **Tone/delivery accuracy** | Partial | Requires **listening pass** — automation cannot certify |
| **Full bench matrix** | **XCUITest only** | `scripts/ios_device.sh bench-ui` — agents never drive matrices |
| **Agent smokes** | Yes | mirroir 1-clip + `measure-*` — [`ui-smoke-runbooks.md`](ui-smoke-runbooks.md) |
| **Pre-merge gates** | Scripts only | `scripts/ios_device.sh gate` — not agent-driven |

**Driving stack:** mirroir native **`tap`/`type_text`** when `check_health` + `describe_screen` pass
(project [`.mirroir-mcp/permissions.json`](../../.mirroir-mcp/permissions.json)). Preflight:
`scripts/ios_mirroir_preflight.sh`.
**Known flaky tap:** Voices bottom-tab label (§1, §6) — use built-in row shortcut to Studio.
**If OCR down:** `ios_device.sh shot` + vision-bridge fallback (Appendix B.3).

### Known product gaps (owner-confirmed)

| Gap | Notes |
| --- | --- |
| **No delete for saved voices** | Clone references and Design-saved voices can be enrolled and reused, but there is **no UI** to remove them (Voices tab, Settings, swipe, etc.). List is **append-only** today. **Future work** — do not fail agent smokes hunting for delete. **Note:** History **can** delete individual **takes** (generated audio rows) — that does **not** remove the saved voice from Voices. |

---

## 1. Navigation hierarchy

The app has **two levels** of navigation on the main surface:

```text
┌─────────────────────────────────────────┐
│  [ Custom | Design | Clone ]  ← mode    │  only when Studio tab selected
│                                         │
│           (mode-specific content)       │
│                                         │
├─────────────────────────────────────────┤
│ Studio │ Voices │ History │ Settings    │  bottom tab bar (always visible)
└─────────────────────────────────────────┘
```

| Layer | User name | Agent notes |
| --- | --- | --- |
| **Bottom tab bar** | Studio · Voices · History · Settings | Primary navigation. Must be on **Studio** to see the generation mode selector. |
| **Mode selector** | Custom · Design · Clone | Segmented control at top of Studio only. Switches compose mode; does **not** change bottom tab. |

**Cold launch:** **Studio** tab + **Custom** mode (default).

**mirroir OCR hints (2026-07-06, 218×486 window):** segment labels **y ≈ 84**; tab labels **y ≈ 406**.
Prior validation at 326×720: segments **y ≈ 108**; tab labels **y ≈ 618–619**; tab icons **y ≈ 689–691**.
Label taps remain more reliable than icon-only taps. **Always re-OCR after move/resize** — coords scale with mirror window height.

---

## 2. Studio — generation mode selector

**When visible:** Only while **Studio** is the selected bottom tab.

**What it is:** Pill-shaped segmented control — **Custom** | **Design** | **Clone**.

| Segment | Default? | Summary |
| --- | --- | --- |
| **Custom** | Yes (boot state) | Built-in speaker + delivery + language; type script; Generate. |
| **Design** | No | Natural-language voice brief + script. |
| **Clone** | No | Reference voice + script. |

**Visual reference (owner screenshot, 2026-07-04):**

- Dark theme; selected segment has lighter pill background (**Custom** selected in capture).
- Status bar above (time, signal, battery); Dynamic Island centered.

**Agent understanding:** Tapping **Design** or **Clone** changes composer copy and bottom controls but stays on Studio tab. OCR after Clone tap showed e.g. *“Type the new text. The reference voice will speak it.”* and *“Voice cloning”*.

---

## 3. Studio — Custom Voice mode

Default screen after launch. Screen marker: `screen_customVoice`. Mode segment:
`generateSection_custom`.

**Vertical layout (Custom mode):**

```text
┌─────────────────────────────────────────┐
│  [ Custom | Design | Clone ]            │
├─────────────────────────────────────────┤
│                                         │
│   Type or paste your script.            │  ← script composer (§3.1)
│   (flexible multi-line editor)          │
│                                         │
│ Built-in voice                   0/150  │  ← meta row (inside composer pad)
├─────────────────────────────────────────┤
│  [ AI ]  [ NE ]  [ AU ]                 │  ← setup chips (§3.2)
├─────────────────────────────────────────┤
│  [ ✨ Generate ]  OR  generating bar    │  ← dock (§3.2, §3.7)
│  OR  live/complete player card          │
└─────────────────────────────────────────┘
```

**Keyboard:** overlays the bottom (chips + dock stay fixed underneath). Dismiss keyboard
(Return/Done on keyboard) before mirroir/Peekaboo **Generate** taps if the CTA is obscured.

### 3.1 Script text area

**What it is:** The main **script composer** — tap here, then type (or paste) the lines you want
the selected voice to **deliver**. This is the text that gets synthesized to speech.

**Visual reference (owner screenshot, 2026-07-04):**

- Large dark area filling most of Studio (between mode selector and meta row).
- No card border — transparent composer on dark canvas.
- Placeholder (empty state): **“Type or paste your script.”** in muted grey at top-left.

| Property | Custom Voice |
| --- | --- |
| **Placeholder** | `Type or paste your script.` |
| **Interaction** | **Tap to focus** → keyboard appears → type or paste |
| **Character limit** | **150** characters on iOS Studio |
| **Meta row** | **Built-in voice** (left) · **`N / 150`** counter (right) — lives **inside** composer pad, above chips |
| **Over limit** | Counter turns **orange** when `N > 150`; warning via `textInput_limitMessage`; **Generate** disabled |
| **XCUITest id** | `textInput_textEditor` |
| **Counter id** | `textInput_lengthCount` |

**Agent driving (mirroir + Peekaboo):**

1. `describe_screen` — placeholder **`Type or paste your script.`** (validation ~**y ≈ 113** at 218×486 window; ~153 at 326×720).
2. Tap **inside** the text area (center of field).
3. Peekaboo `type` with `foreground: true`.
4. Re-`describe_screen` — counter moves off `0/150`; **Generate** enables when other preconditions met (§3.6).

**Note:** Voice Design and Clone reuse the same composer **pattern** but different placeholder copy
(see §4, §5).

### 3.2 Setup chips + dock

Region below the composer: three equal-width **setup chips**, then the **dock** (primary CTA or
player/generating UI).

**Visual reference (owner screenshot, 2026-07-04):**

```
┌──────────────────────────────────────┐
│  [👤 AI ▾]  [🎭 NE ▾]  [🌐 AU ▾]     │  Voice · Delivery · Language
│  [ ✨ Generate          (dimmed) ]   │  or Install / Generating / Player
└──────────────────────────────────────┘
```

| UI label | Meaning | Tap action | XCUITest id |
| --- | --- | --- | --- |
| **AI** | **Aiden** (default speaker), 2-letter abbrev | Opens **voice picker** (§3.5) | `studioChip_voice` (AX prefix `"Voice: "`) |
| **NE** | **Neutral** delivery — see **§3.4** | Opens **delivery picker** | `studioChip_delivery` |
| **AU** | **Auto** language — see **§3.3** | Opens **language picker** | `studioChip_language` |
| **Generate** | Start synthesis | When enabled (§3.6) | `textInput_generateButton` |
| **Install Custom Voice** | Model **not** on device | Jumps to **Settings** tab | `textInput_installModelButton` |

**Important — `AI` is not “artificial intelligence”:** Short label for **Aiden**. mirroir OCR may
read **`Al`** — same control.

**During generation:** chips dim (**50% opacity**) and are **disabled** — config is locked for the
in-flight take. Re-enabled after complete or cancel.

**Agent smoke default:** **Aiden** already selected — no need to open voice picker for basic Custom generate.

**mirroir OCR strings (2026-07-04):** `Built-in voice`, `0/150`, `Al`/`AI`, `NE ^`, `AU ^`, `Generate`,
`Install Custom Voice`, `Generating`, `Rendering audio…`.

**Confirmed tap coords (native mirroir, iPhone 17 Pro — always re-OCR before tap):**

| Window | Calibrated | Generate | Chip row Y | Tab labels Y | Segments Y |
| --- | --- | --- | --- | --- | --- |
| **218×486** (left edge, 2026-07-06) | `1062,132,218,486` | **(114, 394)** | **363** | **406** | **84** |
| 326×720 (2026-07-04) | `919,30,326,720` | (173, 584) | 481–536 | 618–619 | 108 |

| Control | OCR label | Window coords (218×486) | Notes |
| --- | --- | --- | --- |
| **Generate** | `Generate` | **(114, 394)** | Idle dock only; **below** chip row (~y 363). Validated 2026-07-06. |
| Voice chip | `Al ^`, `AI ^`, … | left **x ≈ 53**, **y ≈ 363** | Opens voice picker |
| Delivery chip | `NE ^`, … | middle **x ≈ 119**, **y ≈ 363** | Opens delivery sheet |
| Language chip | `AU ^`, `EN ^` | right **x ≈ 178**, **y ≈ 363** | |
| Script composer | placeholder line | **(79, 113)** | Tap → `press_key` command+a → `type_text` to replace |
| Delivery **Confirm** | `Confirm` | re-OCR | Same Y as voice picker Confirm |
| Inline player **✕** | `X` | **~(185, 387)** | Scaled from 326×720; re-OCR. Confirm **Dismiss** ~**(109, 315)**. |
| Design **Save as voice** | `Save as voice` | **~(109, 389)** | Scaled estimate — re-OCR |
| Design share (illegal) | `*` | **~(160, 361)** | Opens iOS share sheet — do not use for dismiss |

### 3.3 Language chip — **AU** (shared: Custom · Design · Clone)

Rightmost pill in the bottom chip row. **Identical in all three Studio modes.**

**Visual reference (owner screenshot, 2026-07-04):**

```
┌─────────────────┐
│  🌐  AU  ▾      │   ← globe icon + two-letter tag + chevron
└─────────────────┘
```

| Property | Detail |
| --- | --- |
| **Globe icon** | Language / locale selector |
| **AU** | **Auto** — **not** Australia. The UI abbreviates **“Auto”** to its first two letters: **A** + **U** (same rule as **AI** ← Aiden, **NE** ← Neutral). |
| **Chevron (^)** | Opens the **language picker** sheet |
| **Default** | Auto-detect language from the script text |
| **After change** | Tag updates to the chosen language code — e.g. **EN** (English), **FR** (French), **ZH** (Chinese) |
| **XCUITest id** | `studioChip_language` |
| **Picker confirm** | `languagePicker_confirm`; rows `languagePicker_<rawValue>` |

**Agent notes:**

- For a basic smoke, **leave AU (Auto)** — no need to open the picker unless testing a fixed language.
- mirroir OCR: look for **`AU ^`** or **`AU`** near the globe; chevron may appear as `^` on its own line.
- Do **not** confuse **AU** with an accent/region; it means **automatic language detection**.

---

## 3.4 Delivery chip — **NE** + Delivery sheet (shared: Custom · Design · Clone)

Middle pill in the bottom chip row. Controls **how the line is performed** (emotion, pace,
pitch, timbre) — separate from **who** speaks (Custom **AI** / Design **+**) or **which language**
(**AU**).

**Chip (collapsed state):**

```
┌─────────────────┐
│  🎭  NE  ▾      │   ← theater-masks icon + two-letter tag + chevron
└─────────────────┘
```

| Property | Detail |
| --- | --- |
| **Masks icon** | Delivery / performance style |
| **NE** | **Neutral** — default preset. First two letters of **“Neutral”**. |
| **After preset change** | Chip shows preset abbrev — e.g. **Happy** → **HA**, **Sad** → **SA** |
| **Chevron (^)** | Opens **Delivery** bottom sheet |
| **XCUITest id** | `studioChip_delivery` |

**Agent smokes:** leave **NE (Neutral)** unless the run is explicitly testing delivery.

### Delivery sheet (preset picker)

Opened from the **NE** (or **HA**, …) chip. Header: **Delivery** + **Confirm** (top right).

**Visual reference (owner screenshot, 2026-07-04):**

Two-column grid of **10 presets** (colored dot + name + subtitle):

| Preset | Subtitle (on sheet) |
| --- | --- |
| **Neutral** ✓ | Default, even pacing |
| **Happy** | Warm, bright, smiling |
| **Sad** | Quiet, slower, somber |
| **Angry** | Tense, sharp |
| **Fearful** | Quiet, hesitant |
| **Surprised** | Animated, pitch jumps |
| **Excited** | Energetic, faster |
| **Calm** | Slower, reassuring |
| **Whisper** | Soft, close-mic breath |
| **Dramatic** | Theatrical, projected |

Tap a preset to select (checkmark). **Intensity** row below the grid:

| Subtle | **Normal** (default) | Strong |

- **Intensity applies only when a non-Neutral preset is selected** — row is dimmed/disabled for
  Neutral.
- Tap **Confirm** to commit (`deliveryPicker_confirm`).

Preset cells: `deliveryPickerPreset_<id>` (e.g. `deliveryPickerPreset_happy`). Intensity:
`deliveryPickerIntensity_subtle|normal|strong`.

### Custom tone (free-text delivery instructions)

Alternative to the preset grid. Button at bottom of Delivery sheet:

**“Use a custom tone instead”** (`deliveryPickerSheet_customTone`)

Opens a second screen — **Custom tone**:

**Visual reference (owner screenshot, 2026-07-04):**

| Element | Detail |
| --- | --- |
| **Back** (←) | Return to preset grid (`deliveryPickerSheet_customTone_back`) |
| **Title** | Custom tone |
| **Confirm** | Commit custom instruction (top right) |
| **Text field** | Placeholder: *“e.g. An energetic news anchor, bright and fast”* |
| **Hint** | *“Be specific: combine emotion, pace, pitch, and timbre.”* |
| **Examples** | Starter lines (calm narrator, news anchor, whispered close-mic, gentle serious…) |
| **Counter** | **0 / 500** — delivery instruction limit (not the 150-char script limit) |
| **Editor id** | `deliveryPickerSheet_customTone_editor` |

User writes **how** they want the delivery to sound in natural language; that instruction is
sent to the model instead of a preset + intensity. After Confirm, the chip may show a custom
label (abbrev from your text) rather than **NE** / **HA**.

**Do not confuse with Voice Design brief:** Design mode’s **`+`** chip describes **who the voice
is** (identity). **Custom tone** describes **how to perform** the script (delivery) — available
in **all three** Studio modes from the Delivery sheet.

**mirroir OCR hints:** `Delivery`, `Confirm`, preset names (`Neutral`, `Happy`, …),
`Intensity`, `Subtle`, `Normal`, `Strong`, `Use a custom tone instead`, `Custom tone`,
`0/500`, `Be specific`.

### 3.5 Voice picker sheet (Custom only)

Opened from the **AI** (voice) chip. Title: **Voice** · **Confirm** (top right) · **×** dismiss.

| Element | Detail |
| --- | --- |
| **Search** | Filter built-in speakers by name |
| **Language filter chips** | **All** · **English** · **Chinese** · … (from contract) | `voicePickerFilterChip_*` |
| **Speaker rows** | Built-in Qwen3 speakers (Aiden, …) with subtitle + **EN** tag | `voicePickerRow_<id>` |
| **Preview (▶)** per row | Plays bundled preview — **does not** select or close sheet | `voicePickerPreview_<id>` |
| **Row tap** | **Provisional** selection (checkmark) — sheet stays open |
| **Confirm** | Commits speaker → chip updates (e.g. **AI** → **SO** for another name) | `voicePicker_confirm` |

**Language chip independence:** Picking a speaker does **not** pin **AU** — language still follows
script detection (Auto) unless user sets language explicitly (§3.3).

**Voices tab shortcut:** Tapping a **built-in** row in **Voices** jumps here with that speaker
preselected (§6.3).

**Agent smokes:** skip picker — **Aiden** default is enough for Custom generate.

**mirroir OCR:** `Voice`, `Confirm`, `Aiden`, `English`, speaker names, `All`.

### 3.6 Generate readiness (Custom)

**Generate** enables only when **all** are true:

| Precondition | If false |
| --- | --- |
| Script non-empty (after trim) | Generate dimmed (`0/150`) |
| Script ≤ 150 chars | Over-limit warning; Generate dimmed |
| **Custom Voice** model installed | Dock shows **Install Custom Voice** → Settings (§8.1) |
| Engine ready (`ttsEngine.isReady`) | Generate dimmed / lifecycle toast |
| No generation already in flight | Generate dimmed; chips locked |

**Variation** (Settings) and **Autoplay** (Settings) affect output but do not gate the button.

### 3.7 Generation lifecycle (Custom dock)

After **Generate** tap, the dock cycles through states (same card morphs live → complete):

```text
  idle          generating         live                    complete
  [Generate] →  [waveform bar]  →  [Streaming preview]  →  [inline player]
                Generating          play/pause + stop       play/pause + dismiss
                Rendering audio…    (autoplay if ON)        expand → full player
```

| State | Dock UI | IDs / OCR |
| --- | --- | --- |
| **Idle** | **Generate** (or **Install…** if model missing) | `textInput_generateButton` / `textInput_installModelButton` |
| **Generating** (buffering) | Animated waveform + **Generating** · *Rendering audio…* + **stop** | `textInput_cancelButton` |
| **Live preview** | Player card — **Streaming preview**, waveform progress, play/pause, **stop** | `studio_livePreviewPlayer`, `studio_livePreview_playPause`, `studio_livePreview_cancel` |
| **Complete** | Inline **player card** replaces **Generate** — dock **grows taller**; script stays visible above; setup chips re-enabled | `studio_inlinePlayer`, `studio_inlinePlayer_playPause` |
| **Error** | **Generation failed** bar + retry | `textInput_generationError` |

**Owner example — Clone complete state (2026-07-04):** After generating *“Hello”* with reference **AD**
(*A deep, low-pitched*):

```text
┌─────────────────────────────────────────┐
│  [ Custom | Design | Clone ]            │
│  Hello                                  │  ← script remains in composer
│  Voice cloning                    5/150 │
│  [ AD ▾ ]              [ AU ▾ ]         │
│  ┌───────────────────────────────────┐  │
│  │ 0:00 ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  0:01   │  │  scrubber / waveform
│  │ ▶  A deep, low-pitc…              │  │
│  │    Just now · Clone    🔖 ⬇ ✕    │  │  Save · Download · Dismiss
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

| Complete-card element | Behavior |
| --- | --- |
| **Waveform + times** | Playback progress (e.g. `0:00` … `0:01` for short clip) |
| **Play / Pause** | Toggle playback of finished WAV | `studio_inlinePlayer_playPause` |
| **Title line** | Reference / voice name (truncated) |
| **Subtitle** | *Just now · {mode}* — e.g. *Just now · Clone* |
| **Bookmark (Save)** | Share/export WAV (system share sheet) |
| **Download** | Same share/export path |
| **✕ Dismiss** | Confirm *“Dismiss this clip?”* — clears card, returns dock to **Generate** | `studio_inlinePlayer_dismissConfirm` |
| **Tap card** (body) | Expands to **full-screen player** sheet (§9.4) |

Same card morphs from **live preview** → **complete** (one view identity — no swap). **Voice Design**
complete card may also show **Save as voice** (`studio_inlinePlayer_saveAsVoice`); **Clone** and
**Custom** use bookmark/download/dismiss only.

**Agent notes — Design complete card (validated §10.3, 2026-07-04):**

| Control | OCR / coords | Action |
| --- | --- | --- |
| **Save as voice** | `Save as voice` @ y ≈ 576 | Persists designed voice → **Saved voices** + Clone Reference clip pool (§5.4). **Not** dismiss. Optional — only when the run needs that voice as a Clone reference later. |
| **Share / export** | `*` or bookmark icon @ x ≈ 240, y ≈ 534 | Opens **iOS share sheet** — **illegal dismiss target** (G5). |
| **✕ Dismiss** | `X` @ **(276–277, 574)** when visible | Same confirm sheet as Custom/Clone. **Often absent from OCR** when **Save as voice** row is showing — see [B.7 Design dismiss recovery](#b7-multi-clip-reset-and-script-entry). |
| **Save Generated Voice sheet** | `Save Generated Voice` + **X** @ (286, 121) | Opens if dismiss coord is tapped while **Save as voice** is prominent — close **X**; do not tap **Save voice** unless saving. |

**Autoplay (Settings, default ON):** live preview starts playback as soon as enough audio is
buffered — hear speech **before** generation finishes (§8.2).

**Cancel / stop:** aborts in-flight generation; discards partial result; no History row.

**Success:** take saved to **History**; optional **Saved outputs** folder copy (§8.2).

---

## 4. Studio — Voice Design mode

Switch via top segment **Design**. Same overall Studio layout as Custom (script composer above,
control strip below, **Generate** at bottom).

### 4.1 Compared to Custom Voice

| | **Custom** | **Design** |
| --- | --- | --- |
| **Strip header** | Built-in voice | **Designed voice** |
| **First chip** | **AI** (Aiden) — built-in **speaker** picker | **+** (speech-bubble icon) — **voice brief** not set yet |
| **First chip (set)** | Shows speaker abbrev (e.g. `AI`) | Shows first 2 letters of brief text (e.g. `WA` for “Warm…”) |
| **Second chip** | **NE** — Delivery (Neutral) — see **§3.4** | **NE** — Delivery (same) |
| **Third chip** | **AU** — Language (Auto) | **AU** — Language (same) |
| **Script placeholder** | `Type or paste your script.` | `Type the lines you want this designed voice to say.` |
| **Generate requires** | Script text only (+ model ready) | **Voice brief AND script text** (+ model ready) |

**The big difference:** Custom picks an existing **built-in speaker** (Aiden by default). Design
invents a voice from a **natural-language brief** you write first — the **`+`** chip means “add
describe the voice” (opens **Voice brief** sheet). Until the brief is filled, **Generate** stays
dimmed even if the script field has text.

### 4.2 Bottom control strip (Design)

**Visual reference (owner screenshot, 2026-07-04):**

```
┌──────────────────────────────────────┐
│ Designed voice              0 / 150  │
│  [💬 + ▾]  [🎭 NE ▾]  [🌐 AU ▾]      │
│  [ ✨ Generate          (dimmed) ]   │
└──────────────────────────────────────┘
```

| UI label | Meaning | Tap action | XCUITest id |
| --- | --- | --- | --- |
| **Designed voice** | Section title — voice will be **designed** from your brief | — | — |
| **0 / 150** | Script character count (same 150 limit) | — | `textInput_lengthCount` |
| **+** (bubble icon) | **Voice brief unset** — placeholder state | Opens **Voice brief** editor sheet | `studioChip_voiceBrief` |
| *(abbrev e.g. WA)* | Brief is set — shows **prefix of brief text** | Re-open brief editor | `studioChip_voiceBrief` |
| **NE** | Neutral delivery — see **§3.4** (same pill) | Delivery picker | `studioChip_delivery` |
| **AU** | Auto language — see **§3.3** (same pill) | Language picker | `studioChip_language` |
| **Generate** | Synthesize with designed voice | Needs **brief + script** | `textInput_generateButton` |

### 4.3 Script text area (Design)

Same interaction as Custom (**tap → type**), different placeholder:

| Property | Value |
| --- | --- |
| **Placeholder** | `Type the lines you want this designed voice to say.` |
| **XCUITest id** | `textInput_textEditor` (shared) |

### 4.4 Voice brief sheet (first chip)

Opened from the **`+`** / brief chip (`studioChip_voiceBrief`). Bottom sheet — title **Voice brief**,
**Confirm** (top right), **×** dismiss.

**Visual reference — sheet (owner screenshot, 2026-07-04):**

```text
┌─────────────────────────────────────────┐
│  Voice brief                   Confirm  │
│  Describe the voice. Combine character, │
│  age, accent, and texture.              │
│  ┌─────────────────────────────────┐    │
│  │ Young man                       │    │
│  └─────────────────────────────────┘    │
│                            9/500        │
│  STARTING POINTS                        │
│  ┌ A deep, low-pitched male narrator… ┐  │
│  ┌ A bright young woman, energetic…  ┐  │
│  … (catalog starters)                   │
└─────────────────────────────────────────┘
```

| Element | Detail | XCUITest id |
| --- | --- | --- |
| **Hint** | *Describe the voice. Combine character, age, accent, and texture.* | — |
| **Editor** | Free-text voice description; placeholder e.g. *A warm, deep narrator…* | `voiceBrief_editor` |
| **Counter** | **`N/500`** — brief limit (**not** the 150-char script limit) | `voiceBrief_charCount` |
| **Starting points** | Tap a row → **fills brief + dismisses sheet** immediately (no extra Confirm) | `voiceBrief_starter_0`, … |
| **Confirm** | Commits typed brief + dismisses — **disabled when empty** (50% opacity) | `voiceBrief_confirm` |

**Visual reference — after Confirm (owner screenshot, 2026-07-04):**

- First chip **`+`** → **`YO`** (first two letters of **“Young man”** — same abbrev rule as **AI**, **NE**).
- Strip header **Designed voice**; script still empty **`0/150`**.
- **Generate** stays **dimmed** until **both** brief **and** script are non-empty.

| Readiness | Generate |
| --- | --- |
| Brief only (`YO` set, `0/150` script) | **Disabled** |
| Script only (no brief / `+` chip) | **Disabled** |
| Brief + script | **Enabled** |

**Agent smoke minimum:** tap **`+`** → type or pick starter → **Confirm** (if typed) → enter script → **Generate**.

**Do not confuse:** Voice brief = **who the voice is** (Design **`+`** / **`YO`**). Delivery **NE** = **how**
it performs (§3.4). Clone **`+`** = reference audio — different meaning.

**Save → Clone:** After a successful Design generate, user can **save the voice**; it then appears in Clone’s **Reference clip** list (and Voices tab) for reuse — same pool as clone-enrolled references.

**mirroir OCR:** `Voice brief`, `Confirm`, `STARTING POINTS`, `Young man`, `9/500`, `Designed voice`,
`YO`, `NE ^`, `AU ^`, `Type the lines you want this designed`.

---

## 5. Studio — Voice Cloning mode

Switch via top segment **Clone**. Same Studio shell (script above, strip below, **Generate**).

### 5.1 Compared to Custom and Design

| | **Custom** | **Design** | **Clone** |
| --- | --- | --- | --- |
| **Strip header** | Built-in voice | Designed voice | **Voice cloning** |
| **Chip count** | **3** (voice, delivery, language) | **3** (brief, delivery, language) | **2** (reference, language) — **no delivery chip** |
| **First chip** | **AI** (Aiden) | **+** (voice brief) | **+** (waveform) — **reference unset** |
| **First chip (set)** | Speaker abbrev | Brief abbrev | Saved-voice **initials** (e.g. **AD**) or **IM** (recorded clip) |
| **Second chip** | **NE** delivery | **NE** delivery | — |
| **Third chip** | **AU** language | **AU** language | **AU** language |
| **Script placeholder** | Type or paste your script. | Type the lines you want this designed voice to say. | **Type the new text. The reference voice will speak it.** |
| **Generate requires** | Script | Brief + script | **Reference + script** (+ reference transcript ready) |

Clone does **not** expose delivery presets on iOS — performance comes from the **reference audio**, not NE/custom tone.

### 5.2 Bottom control strip (Clone, empty reference)

**Visual reference (owner screenshot, 2026-07-04):**

```
┌──────────────────────────────────────┐
│ Voice cloning               0 / 150  │
│  [〰️ + ▾]              [🌐 AU ▾]    │   ← two chips only
│  [ ✨ Generate          (dimmed) ]   │
└──────────────────────────────────────┘
```

| UI label | Meaning | Tap action | XCUITest id |
| --- | --- | --- | --- |
| **Voice cloning** | Section title | — | — |
| **+** (waveform icon) | **No reference staged** | Opens **Reference clip** sheet | `studioChip_reference` |
| **AU** | Auto language — §3.3 | Language picker | `studioChip_language` |
| **Generate** | Clone synthesis | Needs reference + script | `textInput_generateButton` |

**Note:** Clone **`+`** is **not** the same as Design **`+`**. Here it means **add reference audio** (record or pick saved voice), not voice brief.

### 5.3 Script text area (Clone)

| Property | Value |
| --- | --- |
| **Placeholder** | `Type the new text. The reference voice will speak it.` |
| **Meaning** | New script spoken **in the reference voice’s timbre** — not the reference transcript repeated |
| **XCUITest id** | `textInput_textEditor` |

### 5.4 Reference clip sheet

Opened from the **`+`** / reference chip. Title: **Reference clip** (× to close).

**Visual reference (owner screenshot, 2026-07-04):**

| Option | Detail |
| --- | --- |
| **Record new clip** | Mic icon — *“Capture a 10–20 second sample on this iPhone.”* Opens record flow (mic permission). |
| **Saved voices** | List of enrolled voices on device; subtitle in UI shows *“Cloned reference”* for all rows (generic label — includes voices saved from **Design** too). |

Tap a saved voice row to select (checkmark). Sheet dismisses; reference is staged.

**Design → Clone path:** Generate in **Voice Design** → **Save as voice** → voice appears in **Saved voices** here and in the **Voices** tab → usable as Clone reference. Design also offers **Use in Clone** on the post-save banner to jump straight to Clone with that reference staged.

**Agent smokes:** prefer picking an **existing saved voice** on device over **Record new clip** (no mic / record overlay driving).

### 5.5 After reference is selected

**Visual reference (owner screenshot, 2026-07-04):**

- Left chip shows **initials** from the saved voice name — e.g. **AD** for *“A deep, low-pitched”* (first letter of first two words).
- **AU** unchanged.
- **Generate** enables once reference transcript is ready **and** script text is entered.

Recorded/imported clip (no saved-voice name): chip abbrev **IM** (*“Recorded clip”* in AX).

**Agent smoke minimum:** tap **`+`** → pick saved voice → type script → **Generate**.

**mirroir OCR hints:** `Voice cloning`, `+` or `AD`, `AU ^`, `Type the new text`, `Reference clip`, `Record new clip`, `SAVED VOICES`.

---

## 6. Voices tab

Second bottom tab (**people icon**). Library for **built-in speakers** and **saved voices**
(enrolled references — including voices saved from Design). Not a compose screen; rows **route**
into Studio.

**Visual reference (owner screenshot, 2026-07-04):**

```text
┌─────────────────────────────────────────┐
│  🔍 Search voices                        │
│  [ All ]  Built-in   Saved              │  ← filter chips
│                                         │
│  YOUR SAVED VOICES                      │
│  (AD) A deep, low-pitched  Cloned ref  ▶ │
│  …                                      │
│  ┌─ ─ Save a new voice ─ ─ ─ ─ ─ ─ ─ ┐  │
│  │  Record a 10-20 s reference…     │  │
│  └─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘  │
│                                         │
│  BUILT-IN SPEAKERS                      │
│  (A) Aiden  English-native…    EN  ▶   │
│  …                                      │
├─────────────────────────────────────────┤
│ Studio │ Voices │ History │ Settings    │
└─────────────────────────────────────────┘
```

### 6.1 Chrome

| Element | Purpose | XCUITest id |
| --- | --- | --- |
| **Search voices** | Filter list by name | `voicesSearchField` |
| **All / Built-in / Saved** | Filter chips | `voicesFilter_all`, `voicesFilter_builtIn`, `voicesFilter_saved` |
| Screen marker | — | `screen_voices` |

### 6.2 Your saved voices

Same pool as Clone **Reference clip** sheet (§5.4). Subtitle *“Cloned reference”* on every saved
row — **generic label** (includes Design-saved voices, not clone-only).

| Action | Result |
| --- | --- |
| **Tap row** (avatar + name area — **not** ▶) | Jump to **Studio → Clone** with that voice staged as reference |
| **Play (▶)** | Opens **full-screen player** sheet (§9.4) — previews the **reference clip WAV** + enrollment transcript; **does not** select for Clone or leave Voices tab |
| **Save a new voice** (dashed card) | Record → name → enroll flow (`voices_saveNewVoice`) — same 10–20 s clip as Clone record |

**Visual reference — saved row + preview player (owner screenshots, 2026-07-04):**

```text
Row (Voices tab):
  (M) Me                    Cloned reference   ▶

Player sheet (after ▶ on Me):
┌─────────────────────────────────────────┐
│  ⌄              ● VOICE CLONING         │
│         ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓   │  ← mode-tinted waveform (Clone = copper)
│              Me                         │
│         Saved voice · 0:03              │
│     Salut comment vas-tu                │  ← karaoke highlight follows playback
│  0:02 ━━━━━━━━━━━━━━━━━━━━━━━━━ 0:03   │
│   Save        ⏸ Pause        Download   │
└─────────────────────────────────────────┘
```

| Player field (saved voice ▶) | Value |
| --- | --- |
| **Eyebrow** | **VOICE CLONING** (Clone tint — even for Design-saved voices; preview uses Clone styling) |
| **Title** | Saved voice name (e.g. **Me**) |
| **Subtitle** | **`Saved voice · {duration}`** — not *Just now · Clone* |
| **Transcript** | What the user spoke when enrolling the reference (e.g. *Salut comment vas-tu*) |
| **Autoplay** | Starts on open |
| **Dismiss** | **⌄** (chevron down, top left) → back to Voices list |

Preview accessibility: row ▶ is **`Preview voice`** (no separate id on ▶ — tap right side of row
container `voicesRow_saved_<id>`).

**Owner example (2026-07-04):** Tap saved voice **Me** (not ▶) → **Studio** tab, **Clone** segment,
reference chip shows **`ME`** (first two letters of the name), **AU** language chip, empty script
(*“Type the new text. The reference voice will speak it.”*, `0/150`). Generate stays disabled until
script is non-empty. Same handoff as picking **Me** from Clone’s Reference clip sheet.

Rows: `voicesRow_saved_<id>`. Row body and ▶ are **separate buttons** in code — agents must tap
left of ▶ (avatar/name) to navigate; ▶ only opens preview.

**No delete:** saved voices (clone references and Design-saved) cannot be removed in the UI yet
(see **Known product gaps** above).

### 6.3 Built-in speakers

Contract speakers (e.g. **Aiden**). Language tag pill on the right (**EN**, …).

| Action | Result |
| --- | --- |
| **Tap row** | Jump to **Studio → Custom** with that speaker preselected |
| **Play (▶)** | Same **full-screen player** sheet (§9.4) — bundled preview WAV; eyebrow **CUSTOM VOICE**, subtitle **`Voice preview · {duration}`** |

Rows: `voicesRow_<speakerId>` (e.g. `voicesRow_aiden`).

### 6.4 Agent notes

- **Same saved list** as Clone reference picker — agent can enroll once, reuse from Voices or Clone.
- Prefer **tap row** (not play) when staging Clone reference from this tab.
- Bottom tab: label **Voices** @ y≈618–690 (see §1); was **flaky** from some screens in validation — use label coords from `describe_screen`.
- **mirroir OCR:** `Search voices`, `All`, `Built-in`, `Saved`, `YOUR SAVED VOICES`, `BUILT-IN
  SPEAKERS`, `Cloned reference`, `Save a new voice`, speaker names.

---

## 7. History tab

Third bottom tab (**clock / arrow icon**). Log of **generated takes** (Custom, Design, Clone) —
not the saved-voice library (§6). Each row is one synthesis result with transcript preview,
mode-colored waveform thumbnail, and metadata.

**Visual reference (owner screenshots, 2026-07-04):**

```text
┌─────────────────────────────────────────┐
│  🔍 Search transcript or voice      🗑   │  ← trash = bulk clear menu
│  [ All ]  Cust…   Desi…   Clone         │  ← mode filter chips (+ dots)
│                                         │
│  TODAY                                  │
│  ▓▓ The morning train slipped…    …   │
│     • aiden · Jul 4, 2026 · 6.1s       │
│  ▓▓ Hello there                     …   │  ← … opens row menu
│     • Moi · … · 1.2s                   │
│  …                                      │
├─────────────────────────────────────────┤
│ Studio │ Voices │ History │ Settings    │
└─────────────────────────────────────────┘
```

### 7.1 Chrome

| Element | Purpose | XCUITest id |
| --- | --- | --- |
| **Search transcript or voice** | Filter by transcript text, voice name, or mode | `historySearchField` |
| **Trash (circle)** | Bulk clear menu (disabled when empty) | `historyClearMenu` |
| **All / Custom / Design / Clone** | Mode filter chips (colored dot per mode) | `historyModeFilter`, `historyModeFilter_<mode>` |
| Screen marker | — | `screen_history` |

**Bulk clear menu** (trash icon):

| Option | Effect |
| --- | --- |
| **Clear History (Keep Audio Files)…** | Removes all history **rows** from the database; WAV files stay on disk | `historyClearKeepFiles` |
| **Clear History and Delete Audio…** | Removes rows **and** deletes associated audio files (destructive) | `historyClearDeleteFiles` |

Each option shows a confirmation alert before proceeding.

### 7.2 History rows

Grouped by date bucket: **Today**, **Yesterday**, **Previous 7 Days**, **Previous 30 Days**,
**Earlier**.

Each row shows:

- **Waveform thumbnail** — tinted by mode (Custom = yellow-ish, Design = purple, Clone = orange)
- **Transcript preview** — first lines of generated text
- **Metadata line** — mode dot · **voice name** (or mode label) · date · **duration** (e.g. `6.1s`)

| Action | Result |
| --- | --- |
| **Tap row body** (thumbnail + text) | Opens **full-screen player** sheet (§9.4) | `historyRowTap_<id>` |
| **… (ellipsis menu)** | Row actions menu | `historyRowMenu_<id>` |
| → **Play** | Same as row tap — opens player |
| → **Save audio** | Share/export the WAV (system share sheet) |
| → **Delete** | Confirm *“Delete this take?”* → removes **this history entry and its audio file** | `historyRowDeleteConfirm_<id>` |

Container id: `historyRow_<id>`.

**Important distinction:** deleting a **History take** does **not** delete the saved voice
reference in **Voices** (§6). Clone row showing voice **Me** is a past generation; removing it
does not un-enroll **Me** from saved voices.

### 7.3 Empty / error states

| State | Copy |
| --- | --- |
| No generations yet | *“No takes yet”* |
| Filter/search no match | *“No matches”* |
| Load failure | *“Couldn't load history”* + **Retry** (`historyRetryButton`) |

### 7.4 Agent notes

- **mirroir OCR:** `Search transcript or voice`, `All`, `Custom`/`Cust…`, `Design`/`Desi…`,
  `Clone`, `TODAY`, transcript snippets, voice names, `…` ellipsis, trash menu strings.
- Tap **row body** vs **…** — History: body → player (§9.4); menu → Play / Save / Delete. **Voices**
  is different: body → Studio handoff; **▶ only** → player (§6.2).
- Bulk trash is top-right; per-row Delete is under **…** only.
- Bottom tab: **History** label @ y≈618–690 (see §1).

---

## 8. Settings tab

Fourth bottom tab (**gear icon**). Model downloads, app preferences, links, version footer.
Scrollable — **Voice models** at top, then **Settings**, **About**, Vocello logo + version.

**Visual reference (owner screenshots, 2026-07-04):**

```text
┌─────────────────────────────────────────┐
│  VOICE MODELS                           │
│  Custom Voice    1.7B · 2.31… · Active ✓🗑│
│  Voice Design    1.7B · 2.31… · Active ✓🗑│
│  Voice Cloning   1.7B · 2.34… · Active ✓🗑│
│                                         │
│  SETTINGS                               │
│  Autoplay after generate          [ON]  │
│  Variation              Expressive  ⇅   │
│  Saved outputs    Keep in app (H…    ›  │
│  Storage                    6.96 GB used│
│  Reduce Motion                   [OFF]  │
│  Reduce Transparency              [ON]  │
│                                         │
│  ABOUT                                  │
│  Privacy Policy                      ›  │
│  Open source & licenses              ›  │
│  Open iOS Settings         Permissions ›│
│                                         │
│         [Vocello logo]                  │
│         VERSION 2.0.0                   │
├─────────────────────────────────────────┤
│ Studio │ Voices │ History │ Settings    │
└─────────────────────────────────────────┘
```

### 8.1 Voice models

One row per generation mode — maps 1:1 to Studio segments (Custom / Design / Clone).

| State | Subtitle (approx) | Right-side control |
| --- | --- | --- |
| **Installed** | `1.7B · … · 2.31 GB · **Active**` | Green **checkmark** + **trash** (`iosModelDelete_<id>`) |
| **Not installed** | `1.7B · 4-bit · 2.31 GB` (no **Active**) | Gold **Install** button (`iosModelDownload_<id>`) |
| **Downloading** | `… · **Downloading…**` (may truncate in OCR) | **Cancel** (`iosModelCancel_<id>`); progress bar below row (`iosModelProgress_<id>`) |
| **Paused / interrupted** | **Paused** / **Interrupted** + progress | **Resume** or **Cancel** |
| **Incomplete / error** | **Repair needed** / **Retry needed** | **Repair** / **Retry** |

Row container: `iosModelRow_<id>`.

**Owner example — after deleting Custom Voice (2026-07-04):**

```text
  Custom Voice     1.7B · 4-bit · 2.31 GB     [ Install ]
  Voice Design     1.7B · … · 2.31… · Active    ✓  🗑
  Voice Cloning    1.7B · … · 2.34… · Active    ✓  🗑
```

Custom row lost checkmark/trash and gained **Install**; Design and Clone unchanged. **Storage**
total dropped by ~2.31 GB. **Studio → Custom** will prompt download until **Install** completes.

**Owner example — Install tapped, download in progress (2026-07-04):**

```text
  Custom Voice     1.7B · … · 2.31… · Downloading…   [ Cancel ]
  ▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  33.5 MB / 2.31 GB
  Voice Design     … · Active                          ✓  🗑
  Voice Cloning    … · Active                          ✓  🗑
```

- Progress bar + byte counter appear **below** the row title line.
- **Cancel** opens *“Cancel download?”* — **Cancel Download** (destructive, removes partial data) or
  **Keep Download** (`iosModelCancelDownloadConfirmButton`).
- When complete, row returns to **Active** + checkmark + trash; **Storage** increases.

**Trash on installed row** opens a **Delete model?** bottom sheet — does **not** delete saved voice
references in **Voices** (§6 gap).

**Delete model sheet** (owner example: Custom Voice trash → 2026-07-04):

```text
┌─────────────────────────────────────────┐
│  Delete model?                      ×   │
│  🗑  Custom Voice                       │
│     Frees 2.31 GB. You can reinstall    │
│     later from Settings.                │
│  [ Delete model ]  (red)                │
│  [ Cancel ]                             │
└─────────────────────────────────────────┘
```

| Control | Result |
| --- | --- |
| **×** / swipe dismiss | Close without deleting |
| **Delete model** | Removes on-disk weights; row returns to **Install**; **Storage** total drops | `deleteModelSheet_confirm` |
| **Cancel** | Dismiss sheet |

Same sheet for all three model rows (Custom / Design / Clone). **Storage** row updates after
delete (e.g. `6.96 GB` → lower).

Studio routes here when a mode’s model is missing (`onInstallModel` → Settings tab).

### 8.2 Settings (preferences)

| Row | Type | Notes | XCUITest id |
| --- | --- | --- | --- |
| **Autoplay after generate** | Toggle (**default ON**) | When ON, starts **streaming preview** playback as soon as enough audio is buffered — hear output **before** generation finishes (lower time-to-first-audio). When OFF, generation still streams but user must tap play on the Studio live-preview card. Persists in `UserDefaults` key `autoPlay`. | `iosSettings_autoPlayToggle` |
| **Variation** | Menu (**default Expressive**) | Controls **take-to-take variety** when you regenerate the same script — maps to talker sampling (temperature/top-p), **not** a quality ladder. **Expressive** = official checkpoint defaults (liveliest); **Balanced** / **Consistent** = steadier, more repeatable output. Stamped on every Studio generate (Custom / Design / Clone). Tap row → menu with checkmark on selection. | `iosSettings_variationRow` |
| **Saved outputs** | Confirmation dialog | **Always** keeps clips internally for **History** playback. Optional **second copy** to a user-picked Files folder (incl. iCloud Drive). Default: *“Keep in app (History)”* — internal only, no export copy. | `iosSettings_savedOutputsRow` |

**Saved outputs dialog** (tap row → 2026-07-04):

```text
  Saved outputs
  Generated clips are always kept on this iPhone for History.
  Optionally also copy each new clip to a folder you choose —
  Files or iCloud Drive.

  [ Keep in app (History) ]
  [ Choose a Folder… ]
```

| Option | Effect |
| --- | --- |
| **Keep in app (History)** | Clears external folder bookmark; row shows truncated *“Keep in app (H…”* |
| **Choose a Folder…** | System folder picker; row shows chosen folder name; each new generate **also copies** WAV there (best-effort, never blocks generation) |

Export is **additive** — History and internal storage unchanged. Failed copy does not fail the take.

| **Storage** | Info | Sum of **installed model** bytes (e.g. `6.96 GB used`) — read-only | `iosSettings_storageRow` |
| **Reduce Motion** | Toggle (in-app) | Disables Vocello animations; stored in app prefs | `iosSettings_reduceMotionToggle` |
| **Reduce Transparency** | Toggle (in-app) | Solid surfaces instead of glass; stored in app prefs | `iosSettings_reduceTransparencyToggle` |

### 8.3 About

| Row | Action |
| --- | --- |
| **Privacy Policy** | Opens `https://vocello.vercel.app/privacy` | `iosSettings_privacyPolicyRow` |
| **Open source & licenses** | Opens GitHub repo | `iosSettings_openSourceRow` |
| **Open iOS Settings** | Deep-links to system Settings (*Permissions* — mic/speech recovery) | `iosSettings_openIOSSettingsRow` |

**Brand footer:** Vocello logo + **VERSION** label (`iosSettings_versionLabel`). Version string
from build metadata (device may show e.g. `2.0.0`).

### 8.4 Agent notes

- **Do not confuse** model-row **trash** (§8.1) with saved-voice delete (none — see **Known product gaps**).
- **Storage** row is not tappable — no storage browser on iOS.
- **mirroir OCR:** `Voice models`, `Custom Voice`, `Voice Design`, `Voice Cloning`, `Active`,
  `Autoplay`, `Variation`, `Expressive`, `Storage`, `GB used`, `About`, `Privacy Policy`,
  `Open iOS Settings`, `VERSION`.
- Bottom tab: **Settings** label @ y≈618–690 (see §1).

---

## 9. Sheets and overlays

**What this section is:** A **cross-reference index** for UI that appears **on top of** the four main
tabs — bottom sheets, full-screen covers, dialogs, and transient banners. Most Studio pickers are
already documented inline (§3–§5, §8); §9 collects the rest and flags gaps.

| Overlay | Where documented | Agent priority |
| --- | --- | --- |
| Language picker | **§3.3** | Low — leave **AU** for smokes |
| Delivery picker + custom tone | **§3.4** | Low — leave **NE** for smokes |
| Voice picker (Custom) | **§3.5** | Low — Aiden default |
| Voice brief (Design) | **§4.4** | Medium — needed for Design smokes |
| Reference clip (Clone) | **§5.4** | Medium — pick saved voice vs record |
| Delete model confirmation | **§8.1** | Low |
| Saved outputs dialog | **§8.2** | Low |
| Cancel download dialog | **§8.1** | Low |
| History row menu / bulk clear | **§7** | Low |
| **Full-screen player** | **§9.4** | Medium — Voices ▶, History row, inline player expand |
| **Record + save voice** | **§9.3** | **Avoid** for agent smokes — mic/TCC; use saved voices |
| **Save voice naming sheet** | **§9.3** | Part of record flow |
| **First-run onboarding card** | **§9.1** | Low — dismiss via Settings CTA |
| Engine lifecycle toasts | **§9.5** (thin) | Informational only |
| System folder picker | **§8.2** | OS UI — agent rarely drives |

### 9.1 Onboarding card (first run)

When **no models** are installed, Studio shows a card:

- Title: **Install your first voice**
- Body: download Custom / Design / Clone models on-device
- **Open Settings** → Settings tab (`onboarding_firstRunCard`, `onboarding_openSettings`)

Dismiss by installing any model or navigating away.

### 9.2 Voice brief sheet (Design)

See **§4.4** — title **Voice brief**, 500-char editor, starter rows, **Confirm** disabled when
empty (`voiceBrief_confirm`, `voiceBrief_editor`). Owner screenshot still optional.

### 9.3 Record and save voice (full-screen + naming sheet)

**Entry points:**

| From | Action |
| --- | --- |
| **Voices** tab | **Save a new voice** dashed card (`voices_saveNewVoice`) |
| **Clone** mode | Reference chip **`+`** → Reference clip sheet → **Record new clip** |

Both launch the same **`IOSRecordVoiceSheet`** flow: record overlay → naming sheet → enroll →
**Studio → Clone** with reference staged (Voices tab handoff uses the same enroll path).

**Agent note:** Recording requires the **iPhone microphone on the physical device**. iPhone
Mirroring from Mac **cannot** capture mic input (system may show *micro unavailable from Mac* —
ignore for product docs; **do not** use mirroir/Peekaboo to drive record smokes). Prefer picking an
**existing saved voice** (§5.4, §6.2).

#### Phase A — Reference clip recorder (full-screen overlay)

**Visual reference (owner screenshots, 2026-07-04):**

```text
┌─────────────────────────────────────────┐
│                                    ×    │
│         REFERENCE CLIP                  │
│            00:00                        │
│  Read 10-20 s of clean, natural speech. │
│  Quiet room. One voice.                 │
│         · · · · · · · ·                   │  ← level meter (live while recording)
│      Tap Record to begin.               │
│  [ 🎤 Record ]                          │
└─────────────────────────────────────────┘
```

| State | Header | Status line | Bottom control |
| --- | --- | --- | --- |
| **Idle** | REFERENCE CLIP | *Tap Record to begin.* | **Record** (`iosRecord_start`) |
| **Recording** | RECORDING | *Keep recording. 10 second minimum.* → *Sounds good…* → *Over 20 seconds…* | **Stop** (`iosRecord_stop`) |
| **Captured** (after stop) | CAPTURED | — | **Retake** (`iosRecord_retake`) + **Use this clip** / **Need 10 s** (`iosRecord_use`) |

| Element | Detail |
| --- | --- |
| **×** (top right) | Cancel — discard, close flow | `iosRecord_close` |
| **Timer** | `MM:SS` — turns clone-tint when 10–20 s window met |
| **Level meter** | Live mic amplitude while recording |
| **Duration contract** | **10 s minimum**, **20 s maximum** recommended window |

After **Stop** (or **Use this clip** when ≥10 s), overlay hands off WAV → auto-transcribe runs in
background → **Save this voice** sheet appears.

#### Phase B — Save this voice (bottom sheet)

**Visual reference (owner screenshot, 2026-07-04):**

```text
┌─────────────────────────────────────────┐
│  Save this voice                    ×   │
│  ▶  ·····················  0:00  Ready │
│  Name                                   │
│  [ Name this voice                    ] │
│  What you said  Auto-transcribed·optional│
│  [ What you said in the recording     ] │
│  [ ✓ Save voice ]                       │
└─────────────────────────────────────────┘
```

| Field | Detail |
| --- | --- |
| **Clip review row** | Play/pause preview of recording; **Ready** badge |
| **Name** | Required — placeholder *Name this voice* |
| **What you said** | Auto-transcribed from clip (on-device); user may edit; optional but needed for Clone generate |
| **Save voice** | Enabled when name non-empty; enrolls saved voice |

On success: voice appears in **Voices** + **Reference clip** lists; caller navigates to **Clone**
with reference staged. Quality warnings (clip too short/noisy) may show keep/re-record alert
(`recordVoice_keepDespiteWarning`, `recordVoice_discardOnWarning`).

**mirroir OCR:** `REFERENCE CLIP`, `RECORDING`, `Record`, `Stop`, `Retake`, `Use this clip`,
`Save this voice`, `Name this voice`, `What you said`, `Save voice`, `Ready`.

### 9.4 Full-screen player sheet

Shared **`IOSPlayerSheet`** — modal over whatever tab launched it. Same chrome for **Voices ▶
preview**, **History row tap**, and **Studio inline player card tap** (§3.7). Mode tint + eyebrow
follow the **source** of the audio.

**Visual reference — saved voice preview from Voices ▶ (owner screenshot, 2026-07-04):** see §6.2.

| Element | Detail | XCUITest id |
| --- | --- | --- |
| **Grabber** | Top pill — sheet affordance | — |
| **Dismiss** | **⌄** chevron down (top left) | accessibility label **Close** |
| **Eyebrow** | Mode dot + label — **CUSTOM VOICE** / **VOICE DESIGN** / **VOICE CLONING** | — |
| **Waveform** | Large mode-tinted bars; animates while playing | — |
| **Title** | Voice / speaker name | — |
| **Subtitle** | Context string · duration (see table below) | — |
| **Transcript** | Centered karaoke text — active word highlighted in mode tint | `iosPlayer_transcript` |
| **Scrubber** | Drag thumb or waveform area | `iosPlayer_scrubber` |
| **Time labels** | Current · total (monospaced) | — |
| **Save** | Share/export WAV (system share sheet) | `iosPlayer_save` |
| **Play / Pause** | Center FAB — toggles playback | `iosPlayer_playPause` |
| **Download** | Same share/export as Save | `iosPlayer_download` |

**Autoplay:** sheet **starts playback** when opened (after load).

**Subtitle by entry point:**

| Opened from | Subtitle pattern | Eyebrow |
| --- | --- | --- |
| **Voices ▶** saved row | **`Saved voice · 0:03`** | VOICE CLONING |
| **Voices ▶** built-in row | **`Voice preview · {duration}`** | CUSTOM VOICE |
| **History** row / menu Play | **`{date} · {duration}`** (e.g. *Today · 0:06*) | Matches generation mode |
| **Studio** inline complete card (tap body) | **`Just now · {mode}`** | Matches generation mode |

**Agent distinction (Voices tab):**

| Tap target | Result |
| --- | --- |
| Row body (avatar + name) | **Studio handoff** — §6.2 / §6.3 |
| **▶** only | **Player sheet** — preview only, stay on Voices |

**mirroir OCR:** `VOICE CLONING`, `Saved voice`, `Voice preview`, `CUSTOM VOICE`, `Save`,
`Download`, `Pause` / `Play`, transcript lines, `0:02` / `0:03` scrubber times.

### 9.5 Still open (optional)

| Overlay | Notes |
| --- | --- |
| **Engine lifecycle toasts** | Transient *Preparing runtime* / *Model loading* — informational |
| **System folder picker** | Saved outputs **Choose a Folder…** — OS UI |

---

## Appendix A — OCR ↔ intent cheat sheet

| mirroir OCR (approx) | Agent should interpret as |
| --- | --- |
| `Custom` / `Design` / `Clone` @ y≈108 | Mode segment |
| `Studio` / `Voices` / `History` / `Settings` @ y≈618 | Bottom tab label |
| `Al`, `AI` + person icon | Voice chip (**Aiden** by default) |
| `NE` + masks icon | Delivery chip — **Neutral** (default) |
| `HA`, `SA`, … | Delivery chip after non-neutral preset selected |
| `Delivery` + preset names | Delivery bottom sheet open |
| `Use a custom tone instead` | Entry to custom delivery editor |
| `Custom tone` + `0/500` | Custom delivery instruction screen |
| `AU` + globe icon | Language chip — **Auto** detect (abbreviation of “Auto”, not Australia) |
| `AU ^` | Language chip with chevron (tap target includes `^` in OCR) |
| `EN`, `FR`, `ZH`, … | Language chip after user picked a fixed language |
| `Generating` / `Rendering audio` | Custom mode in-flight (pre-preview) |
| `Streaming preview` | Live preview player during generate |
| `Just now · Custom` / `Just now · Design` / `Just now · Clone` | Complete inline player subtitle (mode label) — poll target after Generate |
| `Save as voice` | Design complete card — persist voice for Clone (§5.4); not dismiss |
| `Save Generated Voice` | Full-screen save sheet — close **X** top-right unless enrolling |
| `Dismiss this clip` | Confirm clearing complete player card |
| `Install Custom Voice` | Model missing — routes to Settings |
| `Voice` / `Confirm` | Custom voice picker sheet |
| `Generate` @ **(114, 394)** | Generate CTA when idle at 218×486 — re-OCR each session |
| Chip row @ **y ≈ 363** | Voice / delivery / language pills — **above** Generate; do not tap NE Y for Generate |
| `ON`, `RY`, `EX`, … + `^` | Voice or delivery chip after non-default selection |
| `X` @ **~(185, 387)** | Dismiss inline player at 218×486; confirm **Dismiss** ~**(109, 315)** — re-OCR |
| `Built-in voice` | Custom mode section header |
| `0/150` | Empty script |
| `Type or paste your script.` | Custom mode script composer (empty) |
| `+` (bubble icon) | Design mode — **voice brief unset** (tap to add brief) |
| `YO`, `WA`, … | Design mode — voice brief set (2-letter abbrev) |
| `Voice brief` / `STARTING POINTS` | Design voice brief sheet |
| `9/500` | Voice brief character counter (not script limit) |
| `Type the lines you want this designed` | Voice Design script composer (empty) |
| `Designed voice` | Design mode section header |
| `Voice cloning` | Clone mode section header |
| `+` + waveform icon | Clone reference chip unset |
| `AD`, `IM`, … | Clone reference chip set (initials or recorded clip) |
| `Reference clip` | Clone reference picker sheet |
| `Search voices` | Voices tab search field |
| `YOUR SAVED VOICES` / `Cloned reference` | Saved voice section / row subtitle |
| `VOICE CLONING` / `Saved voice` | Full-screen player — saved voice ▶ preview |
| `Voice preview` | Full-screen player — built-in speaker ▶ preview |
| `Save a new voice` | Record-new-reference CTA on Voices tab |
| `BUILT-IN SPEAKERS` | Built-in section header |
| `Type the new text. The reference` | Clone script composer (empty) |
| `Search transcript or voice` | History tab search field |
| `TODAY` / `Yesterday` | History date section headers |
| `…` (ellipsis on history row) | Per-row actions menu (Play / Save audio / Delete) |
| `Clear History` / `Delete Everything` | Bulk clear confirmation alerts |
| `Voice models` / `Active` | Settings model section / installed status |
| `Autoplay after generate` | Settings autoplay toggle |
| `Variation` / `Expressive` | Settings sampling variation menu |
| `Balanced` / `Consistent` | Variation menu alternatives |
| `Saved outputs` / `Keep in app` | Optional export-copy destination (History always kept) |
| `Choose a Folder` | Pick Files/iCloud folder for extra WAV copies |
| `REFERENCE CLIP` / `Record` | Record overlay — idle state |
| `RECORDING` / `Stop` | Record overlay — capturing |
| `Save this voice` / `Save voice` | Naming sheet after record |
| `Name this voice` | Required voice name field |
| `GB used` | Settings storage summary (model weights) |
| `Open iOS Settings` / `Permissions` | Deep link to system Settings |
| `Install` | Model row — weights not on device; tap to download |
| `Downloading` / `MB / GB` | Model download in progress |
| `Cancel download` | Confirm abort of in-progress model download |
| `Delete model` / `Frees.*GB` | Delete model confirmation sheet |
| `VERSION` | Settings footer version label |

---

## Appendix B — mirroir agent driving loop

Native iOS UI driving uses [mirroir-mcp](https://github.com/jfarcand/mirroir-mcp) only (no Peekaboo on
the mirror). Coordinates from **`describe_screen`** are **window-relative points** — pass them
directly to **`tap`**.

**Driver choice (2026-07-04):**

| Need | Driver |
| --- | --- |
| Exploratory smokes, owner tours, ad-hoc generate | **mirroir native** (this appendix) + [B.5–B.8](#b5-driving-invariants-mandatory) |
| Full UI bench matrix | **XCUITest** `scripts/ios_device.sh bench-ui` only |
| Future WDA exploratory (deferred) | **mobile-mcp** — see [`mobile-mcp-ios-evaluation.md`](mobile-mcp-ios-evaluation.md) |
| Pre-merge regression | **`scripts/ios_device.sh gate`** (XCUITest) — not agent-driven |

Gates are unchanged regardless of exploratory driver.

### B.1 Preflight (every session)

```bash
scripts/ios_mirroir_preflight.sh --native-only   # skip vision-bridge when native OCR works
scripts/install_mirroir_user_config.sh --merge-settings   # once per machine (permissions + OCR)
```

In Cursor (same **macOS Space** as Recopie de l'iPhone / iPhone Mirroring):

1. **Restart Cursor** after first `permissions.json` install (mirroir defaults fail-closed → ~11 tools).
2. `check_health` → must pass (Screen Recording + Accessibility for **Cursor.app**).
3. `describe_screen` (`omit_screenshot: true` OK) → element list + coords on Studio/Custom.
4. `scripts/ios_device.sh launch` if Vocello not foreground on device.

| Failure | Fix |
| --- | --- |
| Screen capture failed | Allow Screen Recording prompt; same Space as mirror; `ios_device.sh mirror` |
| `'iphone' not open` | French macOS: `mirroringProcessName` in `~/.mirroir-mcp/settings.json` |
| Only ~11 mirroir tools | Run `install_mirroir_user_config.sh`; restart Cursor |
| Paused / welcome mirror | `ios_device.sh mirror` nudges Resume |

### B.2 Custom Voice generate smoke (native)

| Step | mirroir tool | Notes |
| --- | --- | --- |
| 1 | `describe_screen` | Confirm `Generate`, script placeholder, mode segment |
| 2 | `tap` composer coords | From OCR *Type or paste your script* |
| 3 | `type_text` | ≤150 chars; disable iOS autocorrect on test phone if needed |
| 4 | `press_key` return or tap chrome | Dismiss keyboard if **Generate** obscured |
| 5 | `tap` **Generate** coords | From OCR — **below** chip row; never guess NE chip Y. Validated **(114, 394)** at 218×486 (2026-07-06); was (173, 584) at 326×720. |
| 6 | `measure` or poll `describe_screen` | See [measure example](#b2-measure-example) below; poll every 5–8 s (cap 120 s). **No fixed sleeps >15 s.** |
| 7 | History tab (optional) | End-of-session verify only — tap **History** @ y≈406 (218×486) or y≈618 (326×720); confirm new rows with voice + duration |

#### B.2 measure example

Single-clip generate (action + wait in one call):

```text
measure(
  action: "tap:Generate",
  until: "Just now",
  max_seconds: 120,
  name: "custom-generate"
)
```

Multi-clip runs: tap **Generate** separately, then poll `describe_screen` every 5–8 s until
`"Just now • Custom"` and a duration (e.g. `0:09`) appear — never a single 90–130 s sleep.

**Validated 3-clip smoke (2026-07-04, post-permissions restart):** Aiden/NE (5 s), Ryan/Happy (9 s),
Ono Anna/Excited (14 s) — all via native `describe_screen` → `tap`/`type_text`; History showed
`aiden`, `ryan`, `ono_anna` with matching transcripts.

**Voices → Studio handoff (tab recovery only — not mid-session param changes):**

- Use **only** when the **Studio** bottom tab is flaky or you are cold-starting from **Voices**.
- **Voices → Studio Custom:** tap built-in speaker **row body** (e.g. Aiden), not ▶.
- **Voices → Studio Clone:** tap saved voice **row body**, not ▶.
- **Never** open **Voices** between consecutive Custom generates to change voice — use the Studio chip row ([B.5–B.8](#b5-driving-invariants-mandatory)).

**Post-generate:** inline player card — tap body for full-screen player (§9.4); dismiss ✕ → **Dismiss** to regenerate (§B.6).

### B.3 Legacy fallback (Peekaboo + vision bridge)

Use only when **`describe_screen` / `screenshot` fail** but `ios_device.sh shot` shows the phone UI:

1. `scripts/lib/ios_vision_bridge.sh calibrate`
2. Estimate mirror-local coords from shot (or pilot approximations in §1).
3. `to-global X Y` → Peekaboo `click coords:` `foreground: true`
4. Peekaboo `type` for script text

**Higher error rate** (~30–40 px misses on 326×720 window) — e.g. **Generate** tap opening **Delivery**.
Prefer fixing mirroir capture over this path.

### B.4 Vocello mirroir assets (repo)

| Path | Role |
| --- | --- |
| [`.mirroir-mcp/permissions.json`](../../.mirroir-mcp/permissions.json) | Allow `tap`, `type_text`, `measure`, … |
| [`.mirroir-mcp/settings.json`](../../.mirroir-mcp/settings.json) | Force OCR mode, `en-US` |
| [`.mirroir-mcp/skills/apps/Vocello/APP.md`](../../.mirroir-mcp/skills/apps/Vocello/APP.md) | Exploration / agent context |
| [`computer-use-mcp-alternatives-cursor.md`](computer-use-mcp-alternatives-cursor.md) | Full MCP + TCC setup |

Optional: install YOLO `.mlmodelc` in `~/.mirroir-mcp/models/` for tab-bar icon detection ([mirroir docs](https://github.com/jfarcand/mirroir-mcp/blob/main/docs/configuration.md)).

### B.5 Driving invariants (mandatory)

Agents **must** follow these on every mirroir-driven iOS session. See also
[`.cursor/rules/agent-ui-driving.mdc`](../../.cursor/rules/agent-ui-driving.mdc).

| Rule | Rationale |
| --- | --- |
| **O-A-V loop** | Every mutation: `describe_screen` → **one** action → `describe_screen` to confirm. No back-to-back taps. |
| **OCR-only coords** | Never tap from memory, icon estimates, or prior-session coords. Re-OCR after dismiss sheets, keyboard, or tab change. |
| **One recovery path** | If state unclear: `describe_screen` only — not “try another tab.” |
| **No blind retry** | If a tap did not change OCR: do not repeat the same coords; re-OCR and pick the label. |
| **Poll, don't sleep** | Use `measure` or `describe_screen` every 5–8 s (cap 120 s). Ban fixed sleeps >15 s except cold model load. |
| **Stay on Studio for Custom params** | Voice / delivery / language / script / **Generate** change **only via chip row** on Studio → Custom. |
| **Voices tab scope** | **Voices** only when **Studio tab is flaky** or cold-starting from Voices. **Never** between consecutive Custom generates. |
| **Post-generate reset** | Next clip: **X → Dismiss confirm → stay on Studio**. Tap **X** as soon as it appears in OCR after generate completes — **X may drop out of OCR** if you change chips first while the old player is still showing. |
| **Script replace** | See [B.7 script entry protocol](#b7-multi-clip-reset-and-script-entry). **Never** `command+a` → `type_text` without **delete** on iOS mirror. |
| **Generate targeting** | Tap OCR label `Generate` only when visible, **y below chip row**, and **`N / 150` with N > 0** (B.8). If hidden: run [B.7 dismiss poll](#b7-multi-clip-reset-and-script-entry) or reset. |
| **Evidence optional** | `ios_device.sh shot` only when OCR fails or the user asks — not after every generate. |
| **Auto-review** | Use `requestSmartModeApproval: true` on mirroir `tap` / `press_key` in agent smokes when Cursor blocks the call. |

### B.6 Custom Voice multi-clip state machine

```text
IDLE (Generate visible, no inline player; 0/150 or verified script)
  → tap composer → type script → SCRIPT_VERIFY → tap Generate → GENERATING
GENERATING
  → poll describe_screen until "Just now • Custom" + duration → PLAYER_INLINE
PLAYER_INLINE
  → DISMISS_POLL (up to 3× describe, 2 s apart, hunt X label)
  → tap X → DISMISS_CONFIRM → tap Dismiss → IDLE
  → if no X after DISMISS_POLL → RESET (B.7)
IDLE + change voice/delivery (stay on Studio)
  → voice chip → pick → Confirm → delivery chip → pick → Confirm → IDLE
  → tap composer → type script → SCRIPT_VERIFY → Generate → …
VERIFY (optional, end of session only)
  → History tab → OCR top rows → done
```

**Illegal transitions** (observed Jul 4 — do not repeat):

| Transition | Why wrong |
| --- | --- |
| `PLAYER_INLINE → Voices tab` | Voice changes use Studio chip row, not Voices |
| `PLAYER_INLINE → voice/delivery chip` before dismiss | **X** drops out of OCR |
| `PLAYER_INLINE → Generate tap` without dismiss | Generate not in OCR while inline player shows |
| `delivery Confirm → type_text` without composer tap | Text may not stick (G2) |
| `type_text → Generate` without SCRIPT_VERIFY | Empty generate (`0/150`) |
| `command+a → type_text` without delete on mirror | Mangles / 150/150 corruption (G2) |
| `Custom segment tap` / `Design → Custom hop` as reset | Unreliable — use RESET (B.7) |
| `Design PLAYER_INLINE → tap share *` | Opens iOS share sheet — not dismiss (G5) |
| `Design PLAYER_INLINE → tap Save as voice` | Opens save flow — only when enrolling voice for Clone |
| `any → tap` without prior `describe_screen` | Coordinate guess / stale state |
| `unclear state → retry same tap` | Blind retry — re-OCR instead |
| `GENERATING → fixed sleep 90–130 s` | Wastes time — poll every 5–8 s |

**Efficiency targets (B.7):**

| Smoke | Clips | Actions/clip | Session resets |
| --- | --- | --- | --- |
| Custom-only (3-clip) | 3 | ≤12 | ≤2 |
| Multi-mode (9-clip) | 9 | Custom ~12; Design ~16; Clone ~14 | ≤4 |

Zero illegal transitions on all smokes.

### B.6b Voice Design multi-clip (segment **Design**)

Same O-A-V loop as B.6; differences:

- **Mode segment:** tap **Design** @ y ≈ 84 (218×486) or y ≈ 108 (326×720) — stay on **Studio** tab.
- **Readiness:** brief chip set (not `+`) **and** `N / 150` with N > 0 before Generate.
- **Per clip:** `+` or brief chip → Voice brief sheet → type or starter → **Confirm** → composer → script → Generate.
- **Poll:** `"Just now • Design"` + duration.
- **Dismiss:** DISMISS_POLL for **X** — when **Save as voice** @ y ≈ 576 hides **X**, tap **History** → **Studio** (allowed soft recovery), re-OCR, then **X @ (276, 574)**. **Never** tap share `*` @ ~(240, 534).
- **Design → Clone persistence (optional):** tap **Save as voice** after generate to enroll voice in Reference clip pool — skip when reusing a pre-enrolled saved voice.

### B.6c Voice Cloning multi-clip (segment **Clone**)

- **Mode segment:** tap **Clone** @ y ≈ 84 (218×486) or y ≈ 108 (326×720) — stay on **Studio** tab.
- **Reference (once per block):** left chip **`+`** → **Reference clip** sheet → pick first **SAVED VOICES** row (e.g. **AD**) — sheet dismisses; chip shows initials. Reuse same chip for CL2–CL3.
- **Do not** tap **Record new clip** (mic unavailable through mirror).
- **Poll:** `"Just now • Clone"` + duration.
- **Dismiss:** same **X → Dismiss** path as Custom (reliable in OCR).

**Between mode blocks:** `launch` RESET recommended (clears inline player + stale composer). Tap target segment after RESET.

> **Deprecated 2026-07:** Agent full-matrix bench (`bench-ui-mirroir`) removed — use XCUITest
> `bench-ui` only. Historical B.6d procedure archived in
> [`computer-use-mcp-pilot-log.md`](computer-use-mcp-pilot-log.md) §Archived agent bench.

### B.7 Multi-clip reset and script entry

#### After each generate (dismiss poll)

1. Poll until `"Just now • {Custom|Design|Clone}"` + duration (5–8 s interval, cap 120 s). Optional: `measure(action: "tap:Generate", until: "Just now", max_seconds: 120)`.
2. **Within 6 s**, enter **DISMISS_POLL**: up to **3** `describe_screen` calls, **2 s** apart — hunt OCR label **`X`** only (e.g. ~185,387 at 218×486; ~277,574 at 326×720).
3. If **X** found: tap **X** → tap **Dismiss** on confirm sheet → confirm **IDLE** (`Generate` in OCR, no player duration row).
4. If **no X** after 3 polls (common on **Design** when **Save as voice** shows): **History tab → Studio tab** → re-OCR → retry **X** once. If still no **X**: **RESET** (below).
5. Do **not** change chips, Custom segment, or mode hop as reset — except the allowed **History → Studio** hop in step 4.

#### RESET (when dismiss poll fails or script verify fails twice)

| Method | When | Command / tool |
| --- | --- | --- |
| **Primary** | Mirror connected; dismiss/script recovery | `scripts/ios_device.sh launch` (~3 s; French macOS **Recopie de l'iPhone**) |
| **Fallback** | `launch` failed (mirror disconnect) or corrupt `150/150` composer | mirroir `launch_app` name=`Vocello` via Spotlight |
| **Optional** | App Switcher card unambiguous | mirroir `reset_app` name=`Vocello` — **failed** on owner device (*Cannot locate 'Vocello' card*); re-test before preferring |

After RESET: `describe_screen` → confirm **Studio** → target mode segment, `0/150`, **Generate** visible (Design: brief chip set if continuing same block).

#### Script entry protocol (iOS mirror only — not macOS Peekaboo)

| Composer OCR | Protocol |
| --- | --- |
| `0/150` (empty) | Tap composer line → `type_text` → **SCRIPT_VERIFY** (`N > 0`) |
| Non-empty, replace | Tap script line → `command+a` → **`delete`** (×1–3 if needed) → `type_text` → **SCRIPT_VERIFY** |
| Counter shows `150/150` or merged garbage | Tap composer → `command+a` → **`delete` ×3** → verify `0/150` → type-only — or **RESET** |
| SCRIPT_VERIFY fails once | Tap composer → `type_text` again → **SCRIPT_VERIFY** |
| SCRIPT_VERIFY fails twice | **RESET** — do not loop Cmd+A |

**Never:** `command+a` → `type_text` without **delete** between them. Prefer **type-only on `0/150`** over replace when possible (between-clip Custom/Clone).

**Special characters:** mirroir `type_text` may skip unmapped keys (e.g. em dash **—**) — verify counter after type; use ASCII hyphen if needed.

### B.8 Pre-action OCR gates (checklist)

| Before action | OCR must contain |
| --- | --- |
| `type_text` | Composer coords from **prior** `describe_screen`; after delivery/voice Confirm, tap composer first |
| `tap Generate` | Label `Generate`; **`N / 150` with N > 0**; Design also needs brief chip ≠ `+`; no blocking inline player |
| `tap` voice/delivery chip | On Studio → **Custom**; sheet labels (`Voice`, `Delivery`) **absent** |
| `tap` brief chip (`+` / abbrev) | On Studio → **Design**; `Voice brief` sheet absent before tap |
| `tap` reference chip (`+` / initials) | On Studio → **Clone**; pick saved voice — not **Record new clip** |
| `tap` after sheet **Confirm** | Sheet closed — prior sheet title absent; re-OCR delivery/voice chip shows new abbrev (e.g. `EX ^`) |
| `tap` Design player controls | **Not** share `*` or **Save as voice** for dismiss — **X** only (B.7) |
| Recovery | **`describe_screen`**, **History → Studio** (Design dismiss only), or **RESET** — no Voices-tab param detours |

---

## Appendix C — Change log

| Date | Author | Change |
| --- | --- | --- |
| 2026-07-04 | Owner + agent | Initial doc: hierarchy, mode selector, Custom bottom strip; `AI` = Aiden |
| 2026-07-04 | Owner | Custom script composer: tap-to-type, placeholder, 150-char limit |
| 2026-07-04 | Owner | Voice Design strip vs Custom: `+` brief chip, dual readiness |
| 2026-07-04 | Owner | Language chip **AU** = Auto (globe); not Australia |
| 2026-07-04 | Owner | Delivery sheet + **Custom tone** (500-char performance instructions) |
| 2026-07-04 | Owner | Clone mode: 2-chip strip, Reference clip sheet, **AD** initials; Design-saved → Clone ref |
| 2026-07-04 | Owner | Voices tab: saved + built-in sections, filters, row tap → Studio handoff |
| 2026-07-04 | Owner | Voices row tap example: **Me** → Studio Clone, chip **ME**, script empty |
| 2026-07-04 | Owner | **Gap:** no delete for saved clone / Design voices — append-only list |
| 2026-07-04 | Owner | History tab: search, mode filters, row tap → player, … menu, bulk trash |
| 2026-07-04 | Owner | Settings tab: voice models, prefs, About links, version footer |
| 2026-07-04 | Owner | Delete model sheet: Custom Voice trash → confirm, frees 2.31 GB |
| 2026-07-04 | Owner | Post-delete: Custom Voice → **Install**; Design/Clone still **Active** |
| 2026-07-04 | Owner | Install → download progress (`33.5 MB / 2.31 GB`), **Cancel** |
| 2026-07-04 | Owner | **Autoplay after generate**: ON by default; gates streaming preview TTFA |
| 2026-07-04 | Code | **Variation**: Expressive/Balanced/Consistent — sampling consistency, not quality |
| 2026-07-04 | Owner | **Saved outputs**: History always kept; optional folder copy |
| 2026-07-04 | Doc | Custom Voice §3 expanded: voice picker, readiness, lifecycle, install CTA |
| 2026-07-04 | Owner | Record + save voice: REFERENCE CLIP overlay, Save this voice sheet |
| 2026-07-04 | Quiz | Phase 1 complete; agent readiness table; iPhone 17 Pro fixed device; sequential model installs |
| 2026-07-04 | Owner | Post-generate UI: inline player card (Clone *Hello*, AD ref, Just now · Clone) |
| 2026-07-04 | Owner | Voice brief sheet: *Young man* → chip **YO**, starters, 500-char limit |
| 2026-07-04 | Owner | Voices ▶ → full-screen player (*Me*, Saved voice · 0:03, VOICE CLONING) |
| 2026-07-04 | Agent | mirroir native driving: Appendix B, `.mirroir-mcp/` config, preflight script |
| 2026-07-06 | Agent | Left-edge **218×486** mirror recalibration: Generate **(114,394)**, chips y≈363, tabs y≈406, segments y≈84; vision-bridge policy + preflight mirrorBounds |
| 2026-07-04 | Agent | Confirmed Generate **(173, 584)** + chip-row Y band at 326×720; 3-clip Custom smoke validated on device |
| 2026-07-04 | Agent | Appendix B.5 invariants + B.6 multi-clip state machine; agent-ui-driving rule |
| 2026-07-04 | Agent | Appendix B.7 dismiss poll + RESET; B.8 OCR gates; script entry protocol (G1–G4) |
| 2026-07-04 | Agent | B.7–B.8 third 3-clip validation (§10.2 pilot log); `launch` primary RESET; `reset_app` failed |
| 2026-07-04 | Agent | §10.3 nine-clip multi-mode smoke (3× Custom, 3× Design, 3× Clone); Design dismiss via History→Studio; **Save as voice** noted for Design→Clone persistence |
| 2026-07-04 | Agent | B.6b/B.6c Design + Clone multi-clip; B.7 Design dismiss recovery, triple-delete, `launch_app` fallback; B.8 mode gates |
| 2026-07-05 | Agent | B.6d mirroir agent UI bench (`bench-ui-mirroir --agent-drive`); OCR **Clear script** hook; Playbook G |
