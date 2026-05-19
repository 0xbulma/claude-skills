---
name: react-next-best-practices
kind: conditional
trigger: <HAS_REACT>
applies: |
  The project's spec on React / Next.js best practices, if any. The persona
  ALSO loads marketplace skill rubrics at run time — see Step 5 below.
out-of-scope:
  - General type-safety / code smells — see code-quality.
  - Error-handling depth — see silent-failure-hunter.
  - Tailwind class consistency / accessibility — see ui-styling-accessibility.
  - Test coverage for React components — see test-coverage.
focus: React / Next.js patterns — Server Components, `'use client'` discipline, hooks, effects, composition, React 19 APIs.
canonical-rules: |
  Marketplace skills:
   - <HOME>/.claude/skills/vercel-react-best-practices/SKILL.md
   - <HOME>/.claude/skills/vercel-composition-patterns/SKILL.md
  Read both in full at run time and use as the rubric.
---

# React / Next Best Practices

Fires when the diff touches React / Next code (`.jsx` / `.tsx` extension; imports of `react`, `react-dom`, `next/*`, `@tanstack/react-*`, `@apollo/client`; or `'use client'` / `'use server'` directives).

## Run-time setup (MUST do first, in this order)

1. Read `<HOME>/.claude/skills/vercel-react-best-practices/SKILL.md` in full (Read tool, absolute path).
2. Read `<HOME>/.claude/skills/vercel-composition-patterns/SKILL.md` in full (Read tool, absolute path).
3. Use the contents of those two files as the rubric for the review.
4. After reading both files, print two log lines: `Loaded conditional skill: vercel-react-best-practices` and `Loaded conditional skill: vercel-composition-patterns`.

If either file is missing (e.g. the user hasn't installed the marketplace skill), log a single warning `Marketplace skill not found: <name> — degrading to persona's built-in rubric below` and continue with the built-in rubric.

## Review focus (apply with the rubric above)

### Server-Components discipline (Next.js App Router)

- Server Component is the default; `'use client'` should sit on the smallest leaf that needs client interactivity. Flag client directives high in the tree where a child would suffice.
- Data fetching: prefer Server Component `fetch` (with caching directives) over client-side hooks where applicable.
- Streaming and Suspense usage — `<Suspense>` boundaries that wrap meaningful UI sections, not the entire route.

### Composition patterns

- Render-prop / compound-component opportunities for boolean-prop explosions (5+ booleans on one component).
- Context provider placement: providers placed too high cause re-render storms; flag context with frequently-changing values not wrapped in `useMemo` or split.
- Prop-drilling that should be context (3+ levels of pass-through props).

### Hooks + effects

- Effect dependency arrays with stale closures (functions captured before the dependency they should track).
- Missing cleanup in `useEffect` (event listeners, intervals, subscriptions, `AbortController`).
- Memoization that creates new identities every render — `useMemo(() => [a, b], [])` with the array re-created each call defeats the purpose.
- Missing or wrong key props on lists (using index when items can reorder; missing keys entirely).
- Unnecessary client-side state when URL state or server state would do.

### React 19 APIs (when applicable)

- `use()` misuse — only valid in Server Components or Suspense-wrapped contexts.
- Actions / `useActionState` / `useOptimistic` correctness.
- Ref-as-prop (React 19) replacing `forwardRef` where appropriate.

## Severity guidance

- **High** — client-server boundary mistakes: server-only code in a `'use client'` file, secrets leaking to client, environment variables exposed without the `NEXT_PUBLIC_` prefix being intentional.
- **High** — effect / memoization anti-patterns causing infinite loops or render storms.
- **Medium** — composition smells (boolean-prop explosion, prop-drilling that should be context); effect dependency mistakes that cause stale-state bugs but not crashes.
- **Medium** — `'use client'` placed too high in the tree.
- **Low** — minor memoization opportunities; key-prop nits; client-state where URL state would be marginally better.

## Out-of-scope reminders (for the sub-agent)

- Do NOT review generic type-safety or `any` usage — `code-quality`.
- Do NOT review Tailwind classes, design tokens, or accessibility — `ui-styling-accessibility`.
- Do NOT flag missing tests for React components — `test-coverage`.
- Do NOT review error-handling depth in async hooks (missing `.catch()` etc.) — `silent-failure-hunter`.
