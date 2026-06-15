# AGENTS.md

This file provides guidance to AI coding agents when working on the website in this repository.

## What this is

A marketing site for **Vocello** (formerly QwenVoice), a local-first Mac TTS app. Single-page React + Vite. This directory lives inside the QwenVoice monorepo at `website/` and is deployed by Vercel with `website/` as the project root. The site is the brand surface for the app in the parent repo — see "Content accuracy" below. For repo-wide conventions, the app engine, and the source-of-truth order, see the root [`../AGENTS.md`](../AGENTS.md); this file is scoped to the website only.

## Commands

```sh
npm --prefix website run dev      # from repo root: vite dev server on localhost:5173
npm --prefix website run build    # from repo root: production build -> website/dist/
npm --prefix website run preview  # from repo root: serve the production build
```

When already inside `website/`, the equivalent commands are `npm run dev`, `npm run build`, and `npm run preview`.

No tests, no lint config, no GitHub Actions workflow. Behavioral verification is manual + browser-driven; Vercel owns deployment for this directory.

## Tooling for this directory

- This is a **non-app, non-native zone** — do not run the Axiom Swift/iOS auditors here. For React/Vite/library API questions use the `context7` MCP (`resolve-library-id` then `query-docs`); your training data may lag the installed versions.
- For UI/UX/visual passes use the `impeccable:impeccable` skill (the `PRODUCT.md` brand rules below are required reading for it).
- For browser verification of the running dev/preview server, use the `chrome-devtools` MCP (`mcp__plugin_chrome-devtools-mcp_chrome-devtools__*`: `navigate_page`, `take_screenshot`, `take_snapshot`, `list_console_messages`).
- Run `npm`/`node` commands through the Bash tool.

## Architecture

`src/App.jsx` is a **thin composer** (~33 lines). All UI is split across:

- `src/sections/` — one file per page section, in render order: `Nav`, `Hero`, `WorkflowBand` (rendered 3× from data), `Listen`, `WhyCloud`, `TryIt`, `HowItRuns`, `Limitations`, `FinalCTA`, `Footer`.
- `src/components/` — three shared primitives:
  - `Icon.jsx` — single switch over an 18-case SVG vocabulary. Also exports `makeWaveBars` (deterministic bar-height generator).
  - `Waveform.jsx` — bar waveform for Listen rows.
  - `TryCanvas.jsx` — canvas-driven animated waveform for the TryIt demo. Reads `DELIVERY_COLORS` from `data/samples.js` and a local `DELIVERY_SHAPES` table; hashed brief content + per-delivery shape parameters drive the rendering.
- `src/data/` — **single sources of truth**:
  - `workflows.js` (`WORKFLOWS`): the three voice workflow bands' copy + screenshot paths.
  - `samples.js` (`SAMPLES`, `DELIVERIES`, `DELIVERY_COLORS`): Listen samples (with `src` paths into `public/assets/voice-samples/`) + the TryIt delivery picker options.
  - `credits.js` (`CREDITS`, `REPO`, `RELEASE_LATEST`, `RELEASE_V1`): "Built on" tech list + GitHub URLs. Used by `FinalCTA.jsx` for the closing credits roll.
- `src/site.css` + `src/tokens.css` — single global stylesheet (tokens.css is imported from site.css). No CSS modules, no styled components.

### Responsive breakpoints

Three breakpoints in `site.css`, applied universally:

- `<1100px` — hero stacks (copy first, then Mac window).
- `<900px` — workflow bands stack, listen rows stack, runs spec collapses to single column, try-inner stacks, nav-links hide, **all content text-aligns center** (text blocks added `margin-inline: auto` to center as blocks, not just inner text).
- `<600px` — container padding tightens, `formerly QwenVoice` clarifier hides, CTA shrinks.

When changing grid layouts at narrow breakpoints, **use `grid-template-columns: minmax(0, 1fr)` instead of `1fr`** — grid items default to `min-width: auto` which equals content's intrinsic width, and several children (e.g., `.workflow-band-points` with `width: max-content`) force columns wider than the container. Every narrow-breakpoint grid in this file already uses `minmax(0, …)` for this reason.

## Content accuracy (required reading)

Two design-context files in this directory encode the website's rules:

- **`PRODUCT.md`** (i.e. `website/PRODUCT.md`, the brand doc — distinct from the repo-root `PRODUCT.md` app-product doc) — brand voice, register (`brand`, not product), copy rules. Required by the `impeccable:impeccable` skill. Key constraints:
  - Say *local*, not *offline* or *on-device*, unless the technical distinction matters.
  - Sentence case. Reserve all caps for tiny labels only.
  - **No em dashes in visible copy.** Use commas, colons, semicolons, periods, or parentheses. CI for this is a `document.body` text-node walk for the em-dash character — run it after any copy change.
  - No emoji, no celebration copy, no hype claims, no first-person plural.
- **`DESIGN.md`** — color strategy, typography rules, motion rules, bans. Specifically: no gradient text, no side-stripe borders >1px on cards, no decorative glassmorphism, no identical card grids, no repeated uppercase eyebrow scaffolding.

The product's ground truth lives in the parent QwenVoice app repo. When making product claims on the site (model variants, hardware requirements, emotion presets, speaker names, OS requirements), cross-reference:

- `../AGENTS.md` — repo facts: model variant policy, architecture, distribution.
- `../Sources/Resources/qwenvoice_contract.json` — model registry, speakerMetadata, Hugging Face revisions.
- `../Sources/Models/EmotionPreset.swift` — actual emotion presets (8 non-Neutral × 3 intensities + Neutral).
- Voice Cloning has no controllable delivery — the engine path doesn't accept emotion/intensity for clone.

The site has drifted from ground truth multiple times during iteration. Don't trust the existing copy — verify against the upstream.

## Brand tokens (in `tokens.css`)

- **Gold** = Custom Voice (`--gold-300: #EDCC8A`, `--mode-custom`).
- **Lavender** = Voice Design (`--lavender-300: #BFAADB`, `--mode-design`).
- **Terracotta** = Voice Cloning (`--terracotta-300: #DBA887`, `--mode-clone`).
- **Canvas** = charcoal (`--charcoal-900: #16181E`).
- Type stack: SF Pro Text (body), SF Pro Rounded (wordmark), New York / system serif (large display + editorial moments).

Mode colors are referenced via CSS custom properties: rows pass them through `--row-mode`, `--mode-current`, etc. New mode-aware elements should follow this pattern, not hard-code hex values.

## Assets

- `public/assets/screens/` — four Mac app screenshots (`custom-voice.png`, `voice-design.png`, `voice-cloning.png`, `model-downloads.png`).
- `public/assets/voice-samples/` — three WAV clips for the Listen rows; filenames match the `SAMPLES[*].src` field in `data/samples.js`.
- `public/assets/app-icon-1024.png`, `vocello-header-mark.png`, `social_preview.png` — brand artwork.

When adding new audio/image assets, drop them under `public/assets/<category>/` and reference via the data layer, not from JSX directly.

## Conventions worth knowing

- **No client-side router.** Internal links use hash anchors (`#workflows`, `#listen`, `#how-it-runs`, `#download`) on plain `<a>` tags. The nav scroll-progress hairline reads `scrollTop / scrollHeight`.
- **Animations** use the existing `panelSettle` keyframe and `cubic-bezier(0.32, 0.08, 0.24, 1)` ease. Only animate `opacity`, `transform`, `border-color`, and `box-shadow` — never layout properties. `prefers-reduced-motion: reduce` is honored in a single block at the end of `site.css`.
- **Audio playback** in Listen uses one shared `<audio ref>` element with `preload="none"` and src-swap on click for mutual exclusion. See `Listen.jsx`.
