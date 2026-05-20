---
name: styling
version: 1.0.0
kind: conditional
trigger: <HAS_TAILWIND> OR <HAS_STYLING>
applies: |
  The project's design-system spec, if any. Loads the tailwind-design-system
  marketplace skill rubric at run time when <HAS_TAILWIND> is true.
out-of-scope:
  - Accessibility (ARIA, keyboard, focus, alt) — see accessibility.
  - React patterns (Server Components, hooks, effects) — see react-next-best-practices.
  - General code quality — see code-quality.
  - Test coverage — see test-coverage.
focus: |
  Styling consistency, Tailwind discipline, design-token usage.
canonical-rules: |
  Marketplace skills (see references/marketplace-rubrics.md for discovery):
   - tailwind-design-system   (Tailwind v4 — when <HAS_TAILWIND>)
   - web-design-guidelines    (Vercel Web Interface Guidelines — always)
   - building-components      (composable component design)
---

# Styling

Fires when the diff touches Tailwind class strings in JSX or imports a styling library (`styled-components`, `@emotion/*`, `tss-react`, `*.module.css` / `*.module.scss`).

## Run-time setup

Discover marketplace rubric paths via Bash. See `references/marketplace-rubrics.md` for the canonical discovery snippet. Load:

- `tailwind-design-system` — when `<HAS_TAILWIND>` is true
- `web-design-guidelines` — always
- `building-components` — always

For each: if the rubric resolves to a non-empty path, Read it and print `Loaded conditional skill: <name>`. If empty, log degradation and continue with the inline rubric below.

## Styling consistency (always reviewed by this agent)

- New components should use the project's preferred styling approach (per `<PROJECT_CONTEXT>` / the project's component library, if any).
- No mixing styling approaches on the same element (e.g. Tailwind classes + `style={{...}}` inline overrides + `styled-components` on the same node).
- UI component library usage: if the project has a UI library (look for design-system imports), new components should reuse those primitives rather than re-roll.
- Import ordering follows project conventions where defined.
- Colocation: a component's styles should sit with the component (CSS module next to the `.tsx`, Tailwind classes inline, etc.) — not in a far-away stylesheet.

## Tailwind-specific (when `<HAS_TAILWIND>` is true)

- **Design-token consistency.** Use the project's tokens (`bg-primary-500`, `text-muted-foreground`, etc.) over arbitrary values (`bg-[#3b82f6]`, `text-[14px]`) when a token exists.
- **Arbitrary-value smell.** Frequent `[value]` arbitrary classes signal a missing design token — flag the third+ occurrence of the same arbitrary value in the diff.
- **Class ordering.** Follow the project's Tailwind ordering convention if `prettier-plugin-tailwindcss` or similar is configured; otherwise group sensibly (layout → box → typography → color → effects).
- **Dark-mode parity.** Every color class should have a dark variant if the project supports dark mode, OR use semantic tokens that auto-flip.
- **Responsive breakpoint discipline.** Mobile-first: write the base styles for the smallest viewport, add `md:` / `lg:` / etc. for larger.

## Severity guidance

- **Medium** — mixing styling approaches on the same element; hardcoded arbitrary values where a design token exists; missing dark-mode variants when project supports dark mode.
- **Low** — class ordering nits; minor responsive-breakpoint inconsistencies; un-idiomatic but functional code.

## Out-of-scope reminders (for the sub-agent)

- Do NOT review a11y violations (ARIA, keyboard, focus) — `accessibility`.
- Do NOT review React patterns (hooks, effects, Server Components) — `react-next-best-practices`.
- Do NOT review general code quality / type safety — `code-quality`.
- Do NOT propose new design tokens or component primitives — that's design-system work, not PR review.
