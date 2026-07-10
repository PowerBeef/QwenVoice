# Website Engineer

> Agent role for the marketing site under `website/`.

This role is intentionally a **pointer** to the scoped guide that already lives in the
website directory:

- [`website/AGENTS.md`](../website/AGENTS.md)
- [`website/PRODUCT.md`](../website/PRODUCT.md)
- [`website/DESIGN.md`](../website/DESIGN.md)

## When to use this role

Use `.agents/website-engineer.md` (or directly `website/AGENTS.md`) when the task only touches
`website/` — React components, Vite config, CSS tokens, copy, assets, or Vercel deployment.

## Quick commands

```sh
npm --prefix website run dev      # localhost:5173
npm --prefix website run build    # production build → website/dist/
npm --prefix website run preview  # serve the production build
```

## Tools (Codex)

- Use the Browser skill to inspect localhost, verify responsive behavior, take screenshots, and
  check console output against the running dev or preview server.
- Use shell commands for `npm`/`node` workflows.
- For React, Vite, or library API questions, use authoritative current documentation and a
  relevant installed Codex skill/plugin when available.
- Computer Use is an exploratory fallback when browser inspection cannot reach a required UI;
  the production build remains the verification baseline.

## Boundaries

- This is a **non-app, non-native zone** — do not run Swift/iOS/macOS auditors here.
- Product claims must be cross-referenced with `Sources/Resources/qwenvoice_contract.json`,
  root `AGENTS.md`, and `docs/ARCHITECTURE.md`.
- Follow the brand/copy rules in `website/PRODUCT.md` and the design bans in `website/DESIGN.md`.
