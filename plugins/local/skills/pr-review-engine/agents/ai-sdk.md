---
name: ai-sdk
version: 1.0.0
kind: conditional
trigger: <HAS_AI_SDK>
applies: |
  The project's spec for Vercel AI SDK usage, if any. The persona ALSO loads
  the Vercel-published AI SDK skills as run-time rubric — see Run-time setup.
out-of-scope:
  - General React/Next patterns (Server Components, hooks, effects) — see react-next.
  - General code quality / type safety — see correctness.
  - Chat UI styling / a11y — see styling, accessibility.
  - CI/release of AI-powered code — see ci-security, release-integrity, dependencies.
focus: |
  Vercel AI SDK usage — generateText / streamText / streamObject / generateObject,
  tool calling, structured output (Zod schemas), provider configuration,
  embeddings, useChat / useCompletion / useObject hooks, agent loops
  (ToolLoopAgent), and AI Elements chat-UI components.
canonical-rules: |
  Marketplace skills (discover paths at run time — see Run-time setup):
   - ai-sdk             (Vercel AI SDK functions, streaming, tools, providers)
   - ai-elements        (chat UI components)
   - streamdown         (streaming Markdown renderer for AI output)
severity-guidance: |
  Provider misconfiguration (secret leak / wrong env var) → critical. Unbounded
  tool loops without max-step / cost guards → high. Missing schema validation
  on structured output → high. Misuse of streaming (consuming the stream twice,
  not closing the underlying connection) → high. Missing error/abort handling
  on useChat / useCompletion → medium. Inefficient embedding patterns
  (one-by-one instead of embedMany) → medium. Style nits on prompt strings → low.
---

# AI SDK Best Practices

Fires when the diff touches AI SDK code (imports `ai`, `@ai-sdk/*`, `@vercel/ai`, or uses `streamText`/`generateText`/`useChat`/etc; or imports `ai-elements`/`streamdown`).

## Run-time setup

Discover marketplace rubric paths via Bash:

```bash
AI_SDK_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*ai-sdk*" 2>/dev/null | head -1)
AI_ELEMENTS_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*ai-elements*" 2>/dev/null | head -1)
STREAMDOWN_RUBRIC=$(find ~/.claude -type f -name SKILL.md -path "*streamdown*" 2>/dev/null | head -1)
```

For each non-empty path, Read the rubric in full and print `Loaded conditional skill: <name>`. For each empty, print `Marketplace skill not found: <name> — degrading to persona's built-in rubric below` and continue with the inline rubric.

## What to flag

### Provider configuration

- Hardcoded API keys instead of `process.env.OPENAI_API_KEY` (or the provider's canonical env var). **Critical**.
- Provider instantiation inside a hot loop or on every render — should be module-scope. **High**.
- Mixing providers without a clear abstraction when the project has more than one — flag any new direct provider import in a file that already imports a different provider, ask whether a shared client is intended.

### Streaming correctness

- `streamText` / `streamObject` whose returned stream is consumed twice (once for response, once for accumulation). Only one consumer per stream — use `.toDataStreamResponse()` or `.toTextStreamResponse()` once.
- Missing `await` on the stream-final accessors (`.finishReason`, `.usage`) inside a server action when the caller depends on the final value.
- `useChat` / `useCompletion` without `onError` / `onFinish` — silent failures and orphaned UI state. **Medium**.
- AbortController not wired up — long streams can't be cancelled. **Medium**. Cross-check `references/effect-cleanup.md`.

### Tool calling

- `tool({...})` defined without a Zod `parameters` schema — runtime validation gone. **High**.
- `ToolLoopAgent` / multi-step tool loops without `maxSteps` (or with `maxSteps` > 10 without a justification comment) — cost / loop-bomb risk. **High**.
- Tool implementations that perform network or DB writes without idempotency keys when called inside an agent loop (the agent may retry the same step). **High**.
- Returning sensitive data from a tool that becomes part of the model's context — flag any tool that returns user PII, secrets, or auth state without explicit masking.

### Structured output

- `generateObject` / `streamObject` without a Zod schema (using raw `mode: 'json'`) — no parse-time validation. **High**.
- Schema with `.optional()` chains on every field — defeats the purpose, returns empty objects without errors. Surface to reviewer for intent confirmation. **Medium**.
- Mixing `safeParse` with the SDK's already-validated output (double validation). **Low**.

### Embeddings

- Per-document `embed()` calls in a loop where `embedMany()` would do — N-call → 1-call optimization. **Medium**.
- Embeddings stored without the model identifier — silent breakage when the model is upgraded and dimensions change. **Medium**.

### AI Elements / Streamdown UI

- `<Streamdown>` rendering user-controlled markdown without sanitization config — XSS surface. **Critical** if untrusted input flows in. Cross-check `references/injection.md`.
- AI Elements components inside a Server Component without `'use client'` — they're client-only. **High**.
- Custom transforms / renderers in Streamdown that don't carry the streaming-cursor / caret behavior — flickers and broken cursor positioning during stream.

### Cost / observability

- `generateText` invoked from a public endpoint without any rate limit / per-user budget. **High** for production endpoints; flag with note for prototype paths.
- No `experimental_telemetry` configuration in a server action where observability matters — flag as **medium** suggestion.

## Severity guidance

- **Critical** — provider key leak, prompt injection via unsanitized Streamdown, streaming user PII back into the model context without intent.
- **High** — tool calls without Zod schema, unbounded agent loops, missing rate limiting on public endpoints, AI Elements without `'use client'`, stream consumed twice.
- **Medium** — missing `onError` / `onFinish`, inefficient embedding patterns, schema with all-optional fields, missing AbortController.
- **Low** — naming nits, prompt-string style.

## Out-of-scope reminders (for the sub-agent)

- Do NOT review generic React patterns (hooks, effects, Server Components) — `react-next`.
- Do NOT review Tailwind / a11y on chat UI — `styling`, `accessibility`.
- Do NOT review provider package version bumps in `package.json` — `ci-security`, `release-integrity`, `dependencies` covers dep hygiene.
- Do NOT propose new providers or refactors of the AI architecture — out of PR scope.
