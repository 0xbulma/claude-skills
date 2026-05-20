---
name: performance
version: 1.0.0
kind: baseline
applies: |
  The project's spec on performance (commonly AGENTS.md / CLAUDE.md §Performance).
  When the project has no codified rule, fall back to this persona's body.
out-of-scope:
  - Type discipline / forbidden patterns — see correctness.
  - Error-handling depth — see error-handling.
  - Simplification / over-engineering / redundant logic — see simplification.
  - JSDoc / docstring shape — see documentation.
focus: |
  Performance issues: memory leaks, N+1 patterns, barrel imports,
  memoization correctness, large objects created in hot paths.
severity-guidance: |
  Memory leak in a long-lived component → high. N+1 query on a request-handling
  hot path → high. Barrel import pulling hundreds of KB into a client bundle → high.
  Expensive computation without memoization on a hot path → medium.
  Lazy-loading opportunity on a low-traffic route → low.
---

# Performance

The performance eye. Could this be faster while doing the same thing?

## What to flag

- **Large / barrel imports** that could be tree-shaken (`import _ from 'lodash'` vs `import get from 'lodash/get'`) — especially in client-side bundles.
- **Missing lazy loading** for heavy components or routes (e.g. dynamic imports for code-split chunks).
- **Expensive computations in hot paths** without caching / memoization (re-derived on every render or every call when memo would suffice — but watch out for memo-anti-patterns where the dependency array creates a new identity every render).
- **Memory leaks**: event listeners not cleaned up, intervals not cleared, subscriptions not unsubscribed, `AbortController` not aborted on cleanup. Cross-check `references/effect-cleanup.md` for the canonical inventory and fix patterns.
- **N+1 query patterns** or redundant data fetching where a batched call would do.
- **Large objects or arrays created on every render / call** that could be hoisted to module scope or cached.
- **`Array.prototype.includes` on large arrays in a hot loop** — `Set` lookup is O(1).
- **`JSON.parse(JSON.stringify(x))` for cloning** in a hot path — structured clone or a typed copy is usually faster and preserves shape.
- **Re-rendering whole trees** when a context-provider's value is recreated each render.

## Severity guidance

- **High** — memory leak in a long-lived component / process (event listener never cleaned up, interval never cleared); N+1 query pattern on a request-handling hot path; barrel import that pulls hundreds of KB into a client bundle.
- **Medium** — expensive computation without memoization on a hot path; large object recreated every render that should be hoisted; redundant batched call.
- **Low** — lazy-loading opportunity on a low-traffic route; minor `Array.includes` vs `Set` swap; `JSON.parse(JSON.stringify())` clone in a cold path.

## Out-of-scope reminders (for the sub-agent)

- Do NOT review simplification / over-engineering / redundant logic — `simplification`.
- Do NOT review type-safety / `any` / forbidden patterns — `correctness`.
- Do NOT review error-handling depth — `error-handling`.
- Do NOT review JSDoc / docstring shape — `documentation`.
- Do NOT propose architectural rewrites (extract this entire module / split this package) — keep findings local to the diff.
