# Effect cleanup — canonical rubric

Long-lived resources that need explicit teardown: event listeners,
intervals/timeouts, network subscriptions, AbortControllers, streams,
file handles, observer callbacks. Single owner for this concern across
the agent set; agents cross-check this file via the pointer line
`Cross-check \`references/effect-cleanup.md\` when this concern applies.`

## What counts as a cleanup miss

- `addEventListener(...)` without a matching `removeEventListener` in the
  cleanup path (or the cleanup is missing the same `signal: AbortSignal`
  used at registration time).
- `setInterval(...)` without a matching `clearInterval` on unmount /
  teardown.
- `setTimeout(...)` that fires after unmount and updates state (memory
  leak + React "update on unmounted component" warning).
- `useEffect` (React) without a return-value cleanup function when the
  effect creates a subscription, listener, interval, or timer.
- `AbortController` created but never `abort()`'d in the cleanup path; or
  not wired up at all when the call site emits a fetch / stream that
  could outlive the caller.
- Custom subscriptions (RxJS `Subscription`, `EventEmitter.on`, WebSocket
  `onmessage`, SSE `EventSource`, MQTT topic subscribe) without a
  matching `unsubscribe` / `off` / `close` in the teardown.
- Streams (Node `Readable` / `Writable`, browser `ReadableStream`) not
  closed on the error path.
- File handles (`fs.open`, `fs.createReadStream`) not closed in a `finally`
  / `using` block.
- `requestAnimationFrame` not cancelled via `cancelAnimationFrame` on
  unmount.
- `MutationObserver` / `ResizeObserver` / `IntersectionObserver` not
  `disconnect`'d.

## Where to flag

| Context | Severity |
|---|---|
| Long-lived component / process — event listener never cleaned up, interval never cleared | **High** |
| `useEffect` returning nothing while it sets up a listener / interval / subscription | **High** |
| `AbortController` not wired into a `fetch` that could be replaced by a newer request before completing | **Medium** |
| `setTimeout` that fires after potential unmount but does not touch state | **Low** (correctness ok; flag only if hot path) |
| Stream / file handle not closed on error path | **Medium** when in a request-handling path, **Low** elsewhere |

## How to fix

1. **React `useEffect`**: return a cleanup function that mirrors the setup —
   ```ts
   useEffect(() => {
     const c = new AbortController();
     window.addEventListener('foo', handler, { signal: c.signal });
     const t = setInterval(tick, 1000);
     return () => { c.abort(); clearInterval(t); };
   }, [deps]);
   ```
2. **Vanilla JS**: pair every `addEventListener` with a `removeEventListener`
   (same fn ref + capture flag) in the corresponding teardown path;
   alternatively pass `{ signal: AbortSignal }` and call `abort()` to
   remove all listeners attached with that signal at once.
3. **Streams**: wrap in `try { ... } finally { stream.close() }` or use
   `await using` if the runtime supports `Symbol.asyncDispose`.
4. **Subscriptions**: assign to a variable, call `.unsubscribe()` /
   `.off()` / `.close()` in the teardown.

## Out of scope

- Memoization correctness (`useMemo` / `useCallback` dependency hygiene) —
  see `performance` and `react-next`.
- React render-loop issues (stale closures, ref drift) — see `react-next`.
- General over-engineering — see `simplification`.

## Consumers

- `performance` — memory leaks (event listeners, intervals, subscriptions,
  AbortController, streams).
- `react-next` — missing cleanup in `useEffect`, effect dependency drift
  that prevents cleanup.
- `ai-sdk` — `AbortController` not wired up on long-lived streams.
- `runtime-validation` — dev-server lifecycle cleanup on its own teardown.
