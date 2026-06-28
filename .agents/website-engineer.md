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

## Tools

- **`chrome-devtools`** skill (`Skill` tool) for browser automation and verification.
- **`mcp__chrome-devtools__*`** (`navigate_page`, `take_screenshot`, `take_snapshot`,
  `list_console_messages`) for verifying the running site.
- **`context7` MCP** (`mcp__context7__resolve-library-id` → `mcp__context7__query-docs`) for
  React / Vite / library API questions.
- **Bash** for `npm`/`node` commands.

## Boundaries

- This is a **non-app, non-native zone** — do not run Swift/iOS/macOS auditors here.
- Product claims must be cross-referenced with `Sources/Resources/qwenvoice_contract.json`,
  root `AGENTS.md`, and `docs/ARCHITECTURE.md`.
- Follow the brand/copy rules in `website/PRODUCT.md` and the design bans in `website/DESIGN.md`.
