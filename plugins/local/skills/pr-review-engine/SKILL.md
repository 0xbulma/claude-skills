---
name: pr-review-engine
version: 0.1.0
description: Run a parallel multi-lens review of the current diff. Invoked by other skills (pr-review-gh, pr-review-local, pr-fix, tib-ship), not by the user. Walks agents/, decides which apply via diff path patterns and dependency markers, fans out one sub-agent per match, aggregates findings. Replaces the previous lib/pr-review-base.md dispatcher with a real Anthropic-pattern skill (mirrors anthropics/skills/skills/skill-creator).
disable-model-invocation: true
---

# pr-review-engine — shared multi-lens review dispatcher

This skill is the shared review engine for the `pr-review-gh`, `pr-review-local`,
`pr-fix`, and `tib-ship` slash commands. It supersedes the previous shared
dispatcher at `plugins/local/lib/pr-review-base.md`.

Do NOT invoke this skill directly via slash command — it is consumed by other
skills (the `disable-model-invocation` flag enforces this). Callers resolve
branches and head SHA in their own Steps 1–2, then hand control to this skill's
Steps 3–6.

The base contract: callers pass resolved values into Steps 3–6 and consume the
deduplicated findings list + `<FAILED_AGENTS>` count produced by Step 6.

## Inputs (from caller's Steps 1–2)

| Caller-provided | Source |
|---|---|
| `<OWNER>`, `<REPO>` | parsed from git remote |
| `<HEAD_BRANCH>` | `gh pr view` → `headRefName` (PR mode) OR `git branch --show-current` (Local) |
| `<BASE_BRANCH>` | `gh pr view` → `baseRefName` (PR mode) OR auto-detected default branch (Local) |
| `<HEAD_SHA>` | `gh pr view` → `headRefOid` (PR mode) OR `git rev-parse HEAD` (Local) |
| `<DIFF_SOURCE>` | `pr` (use `origin/<BASE>...origin/<HEAD>`) OR `local` (use `origin/<BASE>...HEAD` and overlay uncommitted) |
| `<HEAD_REF>` | `origin/<HEAD_BRANCH>` for `<DIFF_SOURCE>=pr`, `HEAD` for `<DIFF_SOURCE>=local` |
| `<MODE>` | `review` (default) — full review, every matching agent fires. `fix` — only agents whose body contains a `## Fix rubric` section fire (used by `pr-fix` when delegating its rubric set to the engine instead of hardcoding filenames). |
| `<EXCLUDE_AGENTS>` | Optional list of agent names to skip in Step 5 (e.g. `["runtime-validation"]` from `tib-ship` during iterations). Defaults to empty. |

## Step 3: Get the diff locally

**Use the local repo on disk, NOT the GitHub API.**

Compute the merge-base and the diff:

```bash
MERGE_BASE=$(git merge-base origin/<BASE_BRANCH> <HEAD_REF>)

git diff $MERGE_BASE..<HEAD_REF>
git diff --name-only $MERGE_BASE..<HEAD_REF>

# Build the per-file changed-lines map. Used by Step 6 to drop findings whose
# cited line lies far outside any line the diff actually touched. Parse the
# unified=0 hunk headers `@@ -X,Y +A,B @@` — each header announces a block
# starting at line A in the new file with B added/modified lines. When B is
# omitted, treat it as 1.
git diff --unified=0 $MERGE_BASE..<HEAD_REF>
```

Build `<CHANGED_LINES>` as a map `{ "<file-path>": <sorted-int-set> }` from those hunk headers. For each `@@ -OLD,OLD_COUNT +NEW,NEW_COUNT @@` header that follows a `+++ b/<file>` line, add `{NEW, NEW+1, ..., NEW+NEW_COUNT-1}` to that file's set. Two edge cases:

- **Deletion-only hunks** (`NEW_COUNT == 0`): add `NEW` to the set anyway (one line, the new-file line just above the deletion). This preserves adjacent-code findings on a pure deletion — the deletion itself is what made the surrounding code worse, and the line just above is the right anchor.
- **Pure renames** (no hunks at all between a `--- a/<file>` and `+++ b/<file>`): file's set stays empty. Step 6's line-level filter short-circuits when the set is empty (see Step 6 sub-step 1) so adjacent-code findings still survive on a rename-only changed file via the file-level filter alone.

If `<DIFF_SOURCE>=local` AND uncommitted changes exist, also include them:

```bash
git diff HEAD                  # combined staged + unstaged
git diff --name-only HEAD
git diff --unified=0 HEAD      # extend <CHANGED_LINES> with uncommitted hunks
```

Combine the two file lists, deduplicate, announce the count of uncommitted files included so the user knows the review covers their full work-in-progress:

> "Including X uncommitted file(s) in the review."

If both diffs are empty, return an empty result to the caller (it will emit the appropriate "no changes to review" sentinel).

Read each changed file from the local filesystem using the Read tool so agents have full file context (not just diff hunks).

## Step 4: Read project context (adaptive)

Before launching review agents, read project-level documentation that defines the rules and intent of the repo. Store what you find as `<PROJECT_CONTEXT>` and pass it to each agent in Step 5.

### Always read (root-level baseline)

For each file below, read **only** if it exists. Prefer `AGENTS.md` over `CLAUDE.md` to avoid double-reading when one is a symlink to the other:

1. `AGENTS.md` (root). If absent, fall back to `CLAUDE.md` (root).
2. `MISSION.md` — mission, scope, and values (if present).
3. `CONTRIBUTING.md` — dev setup, contribution flow.
4. Lint/format contract: any of `biome.json`, `.eslintrc*`, `.oxlintrc.json`, `.prettierrc*`, `pyproject.toml`, `Cargo.toml`, `go.mod` — read whichever exist, to know the lint/format expectations.

### Conditional baseline (read when relevant)

5. `SECURITY.md` — read if any security-relevant code is touched (auth, crypto, parsers, network entry points, secrets handling, onchain contract calls, wallet operations, CI / publish flow).
6. `docs/jsdoc-style.md` (or similar JSDoc / docstring style guide) — read whenever the diff touches an exported symbol with JSDoc.

### Per-package context (only for packages touched by the diff)

For each unique package directory among the changed files (e.g. a file at `packages/foo/src/bar.ts` belongs to package `packages/foo`), read:

1. `<pkg>/AGENTS.md` — package-specific refinements (refines the root for this package; root wins on contradictions). If absent, fall back to `<pkg>/CLAUDE.md`.
2. `<pkg>/README.md` — public-facing description.
3. `<pkg>/ARCHITECTURE.md` — if present.
4. Any other top-level `*.md` in the package directory.
5. Nested `AGENTS.md` (or `CLAUDE.md`) along the path of touched files (at any depth — e.g. `packages/foo/src/handlers/AGENTS.md`).

Use the Glob tool: `**/AGENTS.md` and `**/CLAUDE.md`. Filter to paths that prefix at least one changed file's directory. Files outside `packages/` use only items 1–4 of the root baseline (items 5–6 conditional as triggered).

### Detect framework / domain signals (used by Step 5 conditional agents)

Compute boolean flags from the diff and from changed files' content. These flags drive which conditional agents launch in Step 5:

- `<HAS_WEB3>` — true if any changed file imports a contract-interaction library (`viem`, `wagmi`, `ethers`, `web3.js` — extend per project with any org-specific Web3 SDK imports, e.g. `@your-org/*`), or contains contract address constants (`0x[a-fA-F0-9]{40}`), or contract interaction patterns (`useContractRead`, `useContractWrite`, `readContract`, `writeContract`, `simulateContract`, `signTypedData`, `permit*`).
- `<HAS_REACT>` — true if any changed file has extension `.jsx`/`.tsx`, OR imports `react`, `react-dom`, `next/*`, `@tanstack/react-*`, `@apollo/client`, OR contains `'use client'` / `'use server'` directives.
- `<HAS_TAILWIND>` — true if `<HAS_REACT>` AND any changed file contains a Tailwind-shaped class string (regex match in JSX: `className="[^"]*\b(flex|grid|p-[0-9]|m-[0-9]|text-|bg-|border-|rounded-)`).
- `<HAS_STYLING>` — true if any changed file imports `styled-components`, `@emotion/*`, `tss-react`, `*.module.css`, `*.module.scss`, OR contains a11y attributes (`role=`, `aria-`, `tabIndex`).
- `<HAS_WORKFLOWS>` — true if any changed file matches `.github/workflows/**`, `.github/actions/**`, or `turbo.json`. Fires `ci-security`.
- `<HAS_RELEASE>` — true if any changed file matches `.changeset/**`, `vercel.json`, OR any `package.json` whose `scripts.*publish*` / `scripts.*release*` / `scripts.*deploy*` field is modified, OR any file containing `changeset publish`, `npm publish`, `pnpm publish`, `gh release create`, `vercel deploy`, or `vercel --prod`. Fires `release-integrity`.
- `<HAS_DEPS>` — true if any changed file matches `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `pnpm-workspace.yaml`, or `.npmrc` (any level). Fires `dependencies`.
- `<HAS_CI_RELEASE>` — derived flag, true iff `<HAS_WORKFLOWS>` OR `<HAS_RELEASE>` OR `<HAS_DEPS>`. Preserved for backward compatibility with `tib-ship/SKILL.md` which still consumes the parent flag for stack-rubric loading. `pr-fix/SKILL.md` was migrated to consume the granular flags directly.
- `<HAS_AI_SDK>` — true if any changed file imports `ai`, `@ai-sdk/*`, `@vercel/ai`, OR uses any of `streamText`, `generateText`, `streamObject`, `generateObject`, `embed`, `embedMany`, `useChat`, `useCompletion`, `useObject`, `ToolLoopAgent`, OR imports `ai-elements` or `streamdown`.
- `<HAS_ROUTE_UI>` — true if any changed file is **route-reachable**, i.e. a page/layout/api-route/SPA entry. Intentionally narrower than `<HAS_REACT>` so we don't boot a dev server for arbitrary component or utility changes. Matches:
  - **Next App Router:** `app/**/page.{tsx,jsx,ts,js}`, `app/**/layout.{tsx,jsx,ts,js}`, `app/**/template.{tsx,jsx}`, `app/**/loading.{tsx,jsx}`, `app/**/error.{tsx,jsx}`, `app/**/route.{ts,js}` (API routes).
  - **Next Pages Router:** `pages/**/*.{tsx,jsx,ts,js}` excluding `pages/_*.{tsx,jsx}` (`_app`, `_document`), `pages/api/**/*.{ts,js}`.
  - **SPA / Vite / Astro:** `src/pages/**/*.{tsx,jsx,astro,mdx}`, `src/routes/**/*.{tsx,jsx}`, `src/App.{tsx,jsx,ts,js}`, `src/main.{tsx,jsx,ts,js}`, `src/index.{tsx,jsx,ts,js}`, `index.html` at repo root.
  - AND the repo has a discoverable dev-server script (`package.json` `scripts.dev` / `scripts.start` / first script matching `^(dev|start|serve)`). If no dev-server command, this flag is false even when route-level files change — the agent has nothing to boot.

  Component-only changes (e.g. `components/Button.tsx`) intentionally do **not** trigger this flag. The agent would have nowhere obvious to navigate; users who want runtime validation in that case should run `/local:tib-ship` (which always runs runtime-validation after convergence).

### Print discovery

After context discovery, print the list of files read and the flags so the user can spot omissions:

```
Context files read (N):
  AGENTS.md (root)
  CONTRIBUTING.md
  packages/foo/AGENTS.md
  ...

Conditional flags:
  Web3:           <HAS_WEB3>
  React/Next:     <HAS_REACT>
  Tailwind:       <HAS_TAILWIND>
  Styling/a11y:   <HAS_STYLING>
  Workflows:      <HAS_WORKFLOWS>
  Release:        <HAS_RELEASE>
  Dependencies:   <HAS_DEPS>
  AI SDK:         <HAS_AI_SDK>
  Route-UI:       <HAS_ROUTE_UI>
```

## Step 5: Launch parallel review agents

Agent specs live in `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/*.md`. Each file has frontmatter declaring `kind: baseline` (always fires) or `kind: conditional` (fires only when its `trigger:` flag is true), plus the prompt body.

### Loop

1. Read every file in `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/*.md`.
2. For each agent, decide whether to launch:
   - `kind: baseline` → always launch.
   - `kind: conditional` → launch only when the flag named in `trigger:` is true (see Step 4 for flag computation). Compound triggers like `<HAS_TAILWIND> OR <HAS_STYLING>` are evaluated as written.
3. **Apply mode filter.** If `<MODE>=fix`, drop any agent whose body does NOT contain a `## Fix rubric` section. Today this filters the launchable set to `web3`, `ci-security`, `release-integrity`, `dependencies`, and `docs` — the five agents whose rubric is the authoritative fix surface consumed by `pr-fix`. When `<MODE>=review` (default), no filter is applied.
4. **Apply the caller's exclusion list.** If the caller provided `<EXCLUDE_AGENTS>` (a list of agent names), drop those from the launch set. Used by orchestrators like `/local:tib-ship` to suppress an agent during inner iterations and run it once explicitly at the end (avoids paying dev-server boot N×, e.g. for `runtime-validation`).
5. Launch ALL selected agents **in parallel** using the Agent tool (subagent_type: `"general-purpose"`).
6. Track `<TOTAL_AGENTS_LAUNCHED>` = count of agents actually launched (baseline + any fired conditionals − mode-filtered − excluded).

### Sub-agent prompt envelope (what the dispatcher must inject)

For every spawned sub-agent, the dispatcher **must** assemble the launch prompt from the following parts, in this order:

1. The agent file body, verbatim (its frontmatter + Markdown prose).
2. `<PROJECT_CONTEXT>` from Step 4 (root + per-package docs, lint contract).
3. The diff in full (committed + uncommitted when `<DIFF_SOURCE>=local`).
4. The full content of changed files (read from local FS via the Read tool).
5. The conditional flag values (`<HAS_REACT>`, `<HAS_WEB3>`, `<HAS_WORKFLOWS>`, etc.).
6. `<CHANGED_LINES>` serialized as JSON: `{ "<path>": [<line>, <line>, ...] }`.
7. **The "Shared per-agent contract" bullets below, copied verbatim into the prompt.** The contract names obligations on the agent (WHAT/FIX schema, line-tolerance window, scope guards) — these MUST be in the sub-agent's context, not just documented here in the dispatcher's SKILL.md. Without this injection, agents won't know to emit the schema and Step 6.2 will route every finding as malformed.
8. **The calibration example pair** (the kept-finding + dropped-finding pair below), copied verbatim. Anchors the agent's output shape.

The dispatcher should NOT paraphrase or summarize these parts — copy them. Drift between the dispatcher's notion of the contract and what the agent receives is exactly the failure mode the engine's schema check is supposed to prevent.

### Shared per-agent contract (applied uniformly to every launched agent)

- Each agent receives: full diff, full content of changed files (read from local FS), `<PROJECT_CONTEXT>` from Step 4, the conditional flag values, `<CHANGED_LINES>` (per-file set of line numbers the diff added or modified), the agent file body, the repo path / branches.
- Per-package `AGENTS.md` rules refine the root for the specific package; the root wins on contradictions.
- Agents must analyze the **full diff**, not just the latest commit.
- Each agent **must return** a JSON array `[{severity: "critical"|"high"|"medium"|"low", file: "path", line: number, description: "WHAT: ... FIX: ..."}]` OR an explicit error sentinel `{"agent_error": "<reason>"}` if it could not complete (the aggregator in Step 6 distinguishes "no findings" from "agent failed").
- **`description` schema.** Every finding's `description` MUST contain both a `WHAT:` clause naming the specific problem AND a `FIX:` clause stating the specific change. Recommended format: `WHAT: <one sentence>. FIX: <one sentence>.` Free-form prose otherwise. Findings without both clauses are rejected as malformed in Step 6 sub-step 2.
- **`line` schema.** `line` must be a positive integer pointing at a line inside `<CHANGED_LINES>` for the cited `file`, OR within ±15 lines of one (the "adjacent code" tolerance window). Findings outside the window are dropped in Step 6 sub-step 1 as pre-existing.
- **Stay in scope (avoid scope creep).** Focus on the diff: flag issues introduced by these changes, and issues in adjacent code only when the diff makes that adjacent code materially worse (e.g. a renamed function whose remaining callers now misbehave, a new code path that exposes an existing bug). Do NOT flag pre-existing issues in unchanged lines of changed files, propose unrelated refactors, suggest new features or abstractions, or recommend cleanups outside the PR's intent. When in doubt, omit — the reviewer is reviewing *this change*, not the file's history.
- **Don't nitpick.** Polish, wording, naming preferences, stylistic alternatives, and "you could also" suggestions are not findings — omit them regardless of severity label. A Low-severity finding belongs in the output only when a reasonable reviewer would clearly act on it in this PR.
- Only **actionable** findings — no praise, no summaries.

#### Calibration examples (apply to every agent)

A finding that would be **kept** (good shape):

```json
{
  "severity": "high",
  "file": "src/components/SearchBox.tsx",
  "line": 42,
  "description": "WHAT: useEffect adds a `window.addEventListener('resize', ...)` but the cleanup function does not call `removeEventListener` with the same handler reference — the listener accumulates on every re-render and leaks. FIX: capture the handler in a variable inside the effect, return `() => window.removeEventListener('resize', handler)` from the effect."
}
```

This is kept because the `WHAT` clause names a specific problem at a specific line, the `FIX` clause is a concrete code change, the severity matches the agent's `severity-guidance:` (memory leak in a long-lived component → high), and the cited line is inside `<CHANGED_LINES>`.

A finding that would be **dropped** in Step 6 (bad shape):

```json
{
  "severity": "medium",
  "file": "src/components/SearchBox.tsx",
  "line": 42,
  "description": "Consider extracting this into a helper for readability."
}
```

This is dropped because: no `WHAT:` clause naming the specific problem, no `FIX:` clause stating the specific change, and the underlying suggestion is a stylistic preference ("for readability") — a textbook nitpick the master scope-guard prohibits. Producing findings like this wastes the human reviewer's attention and pushes them toward auto-dismissing the agent's output.

### Current agent inventory

Baseline (always fire, 6 agents):

- `correctness.md` — type discipline, code smells, naming, security primitives, cross-file impact.
- `error-handling.md` — swallowed errors, missing error states, dead code paths.
- `docs.md` — JSDoc on exports + Markdown doc accuracy + pointer/link integrity + (when project uses an agent system) bidirectional backlink consistency.
- `tests.md` — missing tests, plus layout enforcement (colocation `src/Foo.test.ts` next to `src/Foo.ts` where the project supports it, `*.integration.test.ts` naming for fork-bound tests).
- `simplification.md` — unnecessary complexity, redundant logic, dead branches, over-engineering.
- `performance.md` — barrel imports, memory leaks, N+1, memoization correctness, hot-path allocations.

Conditional (fire only when their trigger flag is true, 9 agents):

- `web3.md` — fires when `<HAS_WEB3>` is true. Contract interactions, transaction params, permit flows, chainId validation.
- `react-next.md` — fires when `<HAS_REACT>` is true. Loads marketplace rubrics (see `references/marketplace-rubrics.md`).
- `styling.md` — fires when `<HAS_TAILWIND>` OR `<HAS_STYLING>` is true. Tailwind/tokens, styling-architecture consistency.
- `accessibility.md` — fires when `<HAS_TAILWIND>` OR `<HAS_STYLING>` is true. ARIA, keyboard, focus, alt text.
- `ci-security.md` — fires when `<HAS_WORKFLOWS>` is true. Workflow injection, action pinning, `permissions:` scopes, secret exposure.
- `release-integrity.md` — fires when `<HAS_RELEASE>` is true. Publish flow, provenance, release-commit signing, Changesets wiring.
- `dependencies.md` — fires when `<HAS_DEPS>` is true. Lockfile drift, dependency hygiene, `.npmrc`, typosquats.
- `ai-sdk.md` — fires when `<HAS_AI_SDK>` is true. Vercel AI SDK usage, streaming, tool calls, structured output.
- `runtime-validation.md` — fires when `<HAS_ROUTE_UI>` is true. Runs a browser via `agent-browser` / `mcp__claude-in-chrome__*` against the dev server: boots, navigates the changed routes, captures console errors / network 4xx-5xx / screenshots. Excluded by `/local:tib-ship` from its iteration loop and run once after static convergence so dev-server boot is paid 1×, not N×.

The dispatcher does not hardcode names — it discovers via `find`. Total: 15 agents (6 baseline + 9 conditional).

Adding a new agent = drop a new file under `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/` with appropriate frontmatter. If conditional, also extend Step 4's flag detection. No edit to caller skill files needed.

## Step 6: Aggregate and deduplicate findings

Merge all agent results into a single list:

1. **Scope filter (drop out-of-scope findings).** Build `<CHANGED_FILES>` = the deduplicated file list from Step 3:
   - committed: `git diff --name-only $MERGE_BASE..<HEAD_REF>`
   - plus uncommitted: `git diff --name-only HEAD` (only when `<DIFF_SOURCE>=local`)

   For every agent finding, first guard `finding.file`: if it is missing, not a string, or empty, treat the finding as malformed and route it to sub-step 2's partial-failure handling instead of dropping it here. Otherwise, compare `finding.file` against `<CHANGED_FILES>` after path normalization:
   - Strip any leading `./`.
   - Strip diff prefixes `a/` and `b/` if present.
   - If the agent returned an absolute path, strip the repo-root prefix (`git rev-parse --show-toplevel`) before compare.
   - Case-sensitive compare (matches git's default).

   If `finding.file` is not in `<CHANGED_FILES>`, **drop the finding** and increment `<DROPPED_OUT_OF_SCOPE>`.

   **Line-level scope filter (in-file).** For findings whose `file` IS in `<CHANGED_FILES>`, check `finding.line` against the file's `<CHANGED_LINES>` set built in Step 3. **First short-circuit:** if the file's `<CHANGED_LINES>` set is empty (pure rename — no hunks contributed any new-file lines), skip the line-level filter for that file entirely. The file-level filter already kept it; don't double-drop. Otherwise:
   - If `finding.line` is in the set → keep.
   - If `finding.line` is outside the set but within ±15 lines of any changed line → keep (the "adjacent code" tolerance: a renamed function's remaining callers, a new code path that exposes an existing bug). The window is deliberately generous to preserve legitimate adjacent findings; agents are not penalized for pointing at the surrounding block.
   - Otherwise → **drop** and increment `<DROPPED_PRE_EXISTING>`. The finding is also tagged with `distance_to_nearest_changed_line` (the integer line-distance to the closest entry in the set) so the audit section can show how far outside the window each drop was — a useful signal when calibrating whether ±15 is the right number for a given codebase.

   The ±15 tolerance window is a fixed engine constant. Future work may expose it as a caller-tunable `<LINE_TOLERANCE>` input if metrics show it needs per-project calibration.

   **Markdown documentation-example filter.** For findings whose `file` ends in `.md` AND whose `description` matches one of the secret/injection FP-suspect patterns (case-insensitive: `secret`, `API key`, `token`, `password`, `_authToken`, `eval(`, `dangerouslySetInnerHTML`, `private key`, `mnemonic`), check whether the cited line falls inside a fenced code block:
   - Read the file. Walk lines `1..(finding.line - 1)` (i.e. stop one line short — a finding cited ON a fence line itself is treated as outside the block, not inside).
   - Count fence markers, where a fence marker is a line whose first three non-whitespace characters are either ` ``` ` (backtick) OR `~~~` (tilde). CommonMark recognizes both; the rule must cover both or it silently misses tilde-fenced examples.
   - If the count is odd, `finding.line` is inside a fenced block → likely a documentation example, not a real defect.
   - Drop the finding and increment `<DROPPED_DOC_EXAMPLE>`.

   This catches the common false positive where an agent flags `OPENAI_API_KEY` or `_authToken=...` inside a code-fence example showing what NOT to do. The filter is deliberately narrow: only `.md` files, only descriptions matching the FP pattern list, only inside backtick or tilde fences. Known limitations (preserved as findings, not silently dropped):
   - **Indented code blocks** (4-space) are NOT detected — a secret-shaped string in an indented block survives the filter. Rare in practice; flag for follow-up if metrics show false-positive rate matters.
   - **Unclosed fences** (odd fence count at EOF, common in partial drafts) cause everything after the unclosed fence to read as "inside a block" — the filter may over-drop. Accepted trade-off; the audit section surfaces the drop for user review.
   - A real hardcoded secret in a `.md` outside a code fence (rare but possible) is preserved as a real finding.

   After all three sub-filters, print one log line per counter that is non-zero:
   `Scope filter: dropped <DROPPED_OUT_OF_SCOPE> file-level + <DROPPED_PRE_EXISTING> line-level + <DROPPED_DOC_EXAMPLE> doc-example finding(s).`

   Note: dropped findings do NOT count toward `<FAILED_AGENTS>` — they are valid output that was simply out of scope, not malformed. They flow to the caller as a collapsible `Dropped by scope filter (N)` section in the final report so the user can audit the filter's decisions and pull a finding back in if the filter was wrong.

2. **Count agent failures.** An agent counts as failed if any of these hold:
   - Returned `{"agent_error": "..."}` (the explicit sentinel from Step 5).
   - Returned text that is not parseable as JSON.
   - Returned a JSON value that is not an array (e.g. an object that is not the error sentinel).
   - Returned an array containing one or more objects missing required fields:
     - `severity` not in `critical`/`high`/`medium`/`low`
     - missing or non-string `file`
     - missing or non-positive-integer `line`
     - missing or empty `description`
     - `description` lacks a `WHAT:` substring OR lacks a `FIX:` substring (per the Step 5 schema)
     Count the agent as **partially failed**: keep the valid findings from that agent, but include the agent in `<FAILED_AGENTS>` so the report flags it.

   Track `<FAILED_AGENTS>` as a count plus the names. This count flows into the caller's Step 7 reporting so a "no findings" verdict is never reported when some agents crashed.

3. **Deduplicate** with this rule (do NOT collapse genuinely distinct findings):
   - Findings on the SAME file at the EXACT same line are duplicates ONLY when their descriptions overlap meaningfully (≥50% token overlap, or one is a clear paraphrase of the other). Keep the one with the higher severity; if descriptions don't overlap, keep BOTH.
   - Findings within ±3 lines but on the same file are merged ONLY when severities AND descriptions overlap.
   - When merging, keep the higher-severity finding's text.

4. Sort by: file path (alphabetical, ASC), then line number (ASC), then severity (DESC).

Severity labels (used everywhere downstream):

- `critical` → Critical
- `high` → High
- `medium` → Medium
- `low` → Low

## Output contract (returned to caller)

The caller (Step 7 of `/local:pr-review-gh` / `/local:pr-review-local` / `/local:pr-fix` / `/local:tib-ship`) consumes:

- `<FINDINGS>` — sorted, deduplicated array of `{severity, file, line, description}`.
- `<DROPPED_FINDINGS>` — findings that the scope filter dropped, each tagged with the drop reason (`file-out-of-scope` / `line-pre-existing` / `doc-example-fp`). Surfaced to the caller as a collapsible audit section, not a silent nuke.
- `<FAILED_AGENTS>` — count + names of agents that returned `agent_error` or malformed output (including findings that failed the WHAT/FIX schema check).
- `<COUNTS>` — `{critical, high, medium, low}` totals on the kept findings.
- `<DROPPED_COUNTS>` — `{out_of_scope, pre_existing, doc_example}` totals on the dropped findings. The keys match the counter names from Step 6 sub-step 1 (`<DROPPED_OUT_OF_SCOPE>` → `out_of_scope`, etc.) — read the named counter, write the matching lowercase key.
- `<TOTAL_AGENTS_LAUNCHED>` — count of baseline + fired conditional agents, minus mode-filtered (when `<MODE>=fix`), minus the caller's `<EXCLUDE_AGENTS>` list. Used by the caller's report to phrase `<FAILED_AGENTS> of <TOTAL_AGENTS_LAUNCHED> agents failed`.

The caller formats and routes these per its mode (GitHub COMMENT / terminal output / fix application).

**Consumer-surfacing state (honest):** as of this commit, none of the four consumer skills (`pr-review-gh`, `pr-review-local`, `pr-fix`, `tib-ship`) yet read `<DROPPED_FINDINGS>` or `<DROPPED_COUNTS>` — they each enumerate only the four pre-filter fields in their Step 6→7 handoff stanzas. Until the consumers are updated (tracked as a follow-up commit), the dropped-findings audit trail is engine-internal: the per-counter log line in Step 6 sub-step 1 is the only surface the user sees. The engine still emits `<DROPPED_FINDINGS>` to the structured output so the data is available for the follow-up to consume; nothing is silently nuked, but the "collapsible audit section" UX is not wired yet.
