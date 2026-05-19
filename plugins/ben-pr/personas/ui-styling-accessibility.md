---
name: ui-styling-accessibility
version: 1.0.0
kind: conditional
trigger: <HAS_TAILWIND> OR <HAS_STYLING>
applies: |
  The project's UI / design-system spec, if any. Loads the tailwind-design-system
  marketplace skill rubric at run time when <HAS_TAILWIND> is true.
out-of-scope:
  - React patterns (Server Components, hooks, effects) — see react-next-best-practices.
  - General code quality — see code-quality.
  - Test coverage — see test-coverage.
focus: |
  UI styling consistency + accessibility (a11y). Tailwind discipline when the
  project uses Tailwind; general styling-architecture concerns (mixed approaches,
  design-token consistency) always; a11y always.
canonical-rules: |
  Marketplace skills (discover paths at run time — see Run-time setup):
   - tailwind-design-system   (Tailwind v4 — when <HAS_TAILWIND>)
   - web-design-guidelines    (Vercel Web Interface Guidelines — always)
   - building-components      (composable, accessible component design)
   - ai-elements              (chat UI components — when AI Elements imports detected)
   - streamdown               (streaming Markdown UI — when streamdown imports detected)
---

# UI / Styling & Accessibility

Fires when the diff touches Tailwind class strings in JSX or imports a styling library (`styled-components`, `@emotion/*`, `tss-react`, `*.module.css` / `*.module.scss`), or contains a11y attributes (`role=`, `aria-`, `tabIndex`).

## Run-time setup

Discover marketplace rubric paths via Bash. Two are always relevant; three are conditionally relevant based on file content:

```bash
TW_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*tailwind-design-system*" 2>/dev/null | head -1)
WDG_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*web-design-guidelines*" 2>/dev/null | head -1)
BUILD_COMP_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*building-components*" 2>/dev/null | head -1)

# Conditional on imports in the diff.
if grep -lE "from ['\"]ai-elements|from ['\"]@ai-sdk/react/elements" <CHANGED_FILES> >/dev/null 2>&1; then
  AI_ELEMENTS_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*ai-elements*" 2>/dev/null | head -1)
fi
if grep -lE "from ['\"]streamdown" <CHANGED_FILES> >/dev/null 2>&1; then
  STREAMDOWN_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*streamdown*" 2>/dev/null | head -1)
fi
```

1. **If `<HAS_TAILWIND>` is true** and `$TW_RUBRIC` is non-empty, Read it and print `Loaded conditional skill: tailwind-design-system`. If empty, log degradation and continue.
2. **Always**: if `$WDG_RUBRIC` is non-empty, Read it and print `Loaded conditional skill: web-design-guidelines`. If empty, log degradation.
3. **Always**: if `$BUILD_COMP_RUBRIC` is non-empty, Read it and print `Loaded conditional skill: building-components`. If empty, log degradation.
4. **If `AI_ELEMENTS_RUBRIC` was set and is non-empty**, Read it and print `Loaded conditional skill: ai-elements`.
5. **If `STREAMDOWN_RUBRIC` was set and is non-empty**, Read it and print `Loaded conditional skill: streamdown`.
6. **Always** cover accessibility and styling-consistency concerns below.

## Accessibility (always reviewed by this agent)

- Missing or incorrect ARIA attributes (`aria-label`, `aria-describedby`, `aria-labelledby`, correct `role` values).
- Interactive elements not keyboard-accessible: missing `tabIndex`, `onKeyDown` handlers; `<div onClick=...>` without keyboard equivalent.
- Missing alt text on `<img>`, missing labels on form inputs (`<label>` associated by `htmlFor` or `aria-label`).
- Color contrast issues (text on background) when detectable from code — flag when a low-contrast token pair is hardcoded.
- Focus management issues: modals / dialogs / dropdowns not trapping focus, not restoring focus on close.
- `tabindex` values > 0 (causes confusing tab order — should always be 0 or -1).

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

- **High** — accessibility violations that block keyboard / screen-reader users (missing labels, `<div onClick>` with no keyboard equivalent, focus traps broken).
- **Medium** — mixing styling approaches on the same element; hardcoded arbitrary values where a design token exists; missing dark-mode variants when project supports dark mode.
- **Low** — class ordering nits; minor responsive-breakpoint inconsistencies; un-idiomatic but functional code.

## Out-of-scope reminders (for the sub-agent)

- Do NOT review React patterns (hooks, effects, Server Components) — `react-next-best-practices`.
- Do NOT review general code quality / type safety — `code-quality`.
- Do NOT review error-handling depth — `silent-failure-hunter`.
- Do NOT propose new design tokens or component primitives — that's design-system work, not PR review.
