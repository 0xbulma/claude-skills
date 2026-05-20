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
| `<EXCLUDE_AGENTS>` | Optional list of agent names to skip in Step 5 (e.g. `["runtime-validation"]` from `tib-ship` during iterations). Defaults to empty. |

## Step 3: Get the diff locally

**Use the local repo on disk, NOT the GitHub API.**

Compute the merge-base and the diff:

```bash
MERGE_BASE=$(git merge-base origin/<BASE_BRANCH> <HEAD_REF>)

git diff $MERGE_BASE..<HEAD_REF>
git diff --name-only $MERGE_BASE..<HEAD_REF>
```

If `<DIFF_SOURCE>=local` AND uncommitted changes exist, also include them:

```bash
git diff HEAD                  # combined staged + unstaged
git diff --name-only HEAD
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
- `<HAS_CI_RELEASE>` — true if any changed file matches `.github/workflows/**`, `.github/actions/**`, `.changeset/**`, `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `pnpm-workspace.yaml`, `.npmrc` (any level), `turbo.json`, `vercel.json`, OR any `package.json` whose `scripts.*publish*` / `scripts.*release*` / `scripts.*deploy*` field is modified, OR any file containing `changeset publish`, `npm publish`, `pnpm publish`, `gh release create`, `vercel deploy`, or `vercel --prod`.
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
  CI/release:     <HAS_CI_RELEASE>
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
3. **Apply the caller's exclusion list.** If the caller provided `<EXCLUDE_AGENTS>` (a list of agent names), drop those from the launch set. Used by orchestrators like `/local:tib-ship` to suppress an agent during inner iterations and run it once explicitly at the end (avoids paying dev-server boot N×, e.g. for `runtime-validation`).
4. Launch ALL selected agents **in parallel** using the Agent tool (subagent_type: `"general-purpose"`).
5. Track `<TOTAL_AGENTS_LAUNCHED>` = count of agents actually launched (baseline + any fired conditionals − excluded).

### Shared per-agent contract (applied uniformly to every launched agent)

- Each agent receives: full diff, full content of changed files (read from local FS), `<PROJECT_CONTEXT>` from Step 4, the conditional flag values, the agent file body, the repo path / branches.
- Per-package `AGENTS.md` rules refine the root for the specific package; the root wins on contradictions.
- Agents must analyze the **full diff**, not just the latest commit.
- Each agent **must return** a JSON array `[{severity: "critical"|"high"|"medium"|"low", file: "path", line: number, description: "what is wrong + how to fix"}]` OR an explicit error sentinel `{"agent_error": "<reason>"}` if it could not complete (the aggregator in Step 6 distinguishes "no findings" from "agent failed").
- **Stay in scope (avoid scope creep).** Focus on the diff: flag issues introduced by these changes, and issues in adjacent code only when the diff makes that adjacent code materially worse (e.g. a renamed function whose remaining callers now misbehave, a new code path that exposes an existing bug). Do NOT flag pre-existing issues in unchanged lines of changed files, propose unrelated refactors, suggest new features or abstractions, or recommend cleanups outside the PR's intent. When in doubt, omit — the reviewer is reviewing *this change*, not the file's history.
- **Don't nitpick.** Polish, wording, naming preferences, stylistic alternatives, and "you could also" suggestions are not findings — omit them regardless of severity label. A Low-severity finding belongs in the output only when a reasonable reviewer would clearly act on it in this PR.
- Only **actionable** findings — no praise, no summaries.

### Current agent inventory

Baseline (always fire):

- `code-quality.md` — type discipline, code smells, naming, security primitives, cross-file impact.
- `silent-failure-hunter.md` — swallowed errors, missing error states, dead code paths.
- `documentation.md` — JSDoc on exports + Markdown doc accuracy + pointer/link integrity + (when project uses an agent system) bidirectional backlink consistency.
- `test-coverage.md` — missing tests, plus layout enforcement (colocation `src/Foo.test.ts` next to `src/Foo.ts` where the project supports it, `*.integration.test.ts` naming for fork-bound tests).
- `code-simplifier-performance.md` — unnecessary complexity, redundant logic, performance issues.

Conditional (fire only when their trigger flag is true):

- `web3-security.md` — fires when `<HAS_WEB3>` is true. Contract interactions, transaction params, permit flows, chainId validation.
- `react-next-best-practices.md` — fires when `<HAS_REACT>` is true. Loads marketplace rubrics: `vercel-react-best-practices`, `vercel-composition-patterns`, `next-best-practices`, `next-cache-components`, `building-components`, and `vercel-react-native-skills` (only when React Native is detected).
- `ui-styling-accessibility.md` — fires when `<HAS_TAILWIND>` OR `<HAS_STYLING>` is true. Loads `tailwind-design-system`, `web-design-guidelines`, `ai-elements`, `streamdown`, `building-components` as rubric when applicable.
- `ci-release-security.md` — fires when `<HAS_CI_RELEASE>` is true. Workflow injection, action pinning, write-token hardening, lockfile drift, publish-flow integrity. Loads `github-actions-docs`, `turborepo`, `deploy-to-vercel`, `vercel-cli-with-tokens` as rubric.
- `ai-sdk-best-practices.md` — fires when `<HAS_AI_SDK>` is true. Vercel AI SDK usage, streaming, tool calls, structured output, useChat/useCompletion. Loads `ai-sdk`, `ai-elements`, `streamdown` as rubric.
- `runtime-validation.md` — fires when `<HAS_ROUTE_UI>` is true. Runs a browser via `agent-browser` / `mcp__claude-in-chrome__*` against the dev server: boots, navigates the changed routes, captures console errors / network 4xx-5xx / screenshots. Excluded by `/local:tib-ship` from its iteration loop and run once after static convergence so dev-server boot is paid 1×, not N×.

The dispatcher does not hardcode names — it discovers via `find`. The list above documents what currently exists; persona refinement (splits and renames) is tracked in TIP-2026-05-20-persona-refinement and lands in a follow-up PR.

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

   Do NOT filter by line number within a changed file. The Step 5 contract permits flagging adjacent code in a changed file when the diff materially worsens it, so line-level filtering would discard legitimate findings.

   After the loop, print one log line: `Scope filter: dropped <DROPPED_OUT_OF_SCOPE> finding(s) targeting files outside the diff.` Then proceed to the remaining sub-steps on the surviving findings.

   Note: dropped findings do NOT count toward `<FAILED_AGENTS>` — they are valid output that was simply out of scope, not malformed.

2. **Count agent failures.** An agent counts as failed if any of these hold:
   - Returned `{"agent_error": "..."}` (the explicit sentinel from Step 5).
   - Returned text that is not parseable as JSON.
   - Returned a JSON value that is not an array (e.g. an object that is not the error sentinel).
   - Returned an array containing one or more objects missing required fields (`severity` not in `critical`/`high`/`medium`/`low`, missing or non-string `file`, missing or non-numeric `line`, missing or empty `description`) — count the agent as **partially failed**: keep the valid findings from that agent, but include the agent in `<FAILED_AGENTS>` so the report flags it.

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
- `<FAILED_AGENTS>` — count + names of agents that returned `agent_error` or malformed output.
- `<COUNTS>` — `{critical, high, medium, low}` totals.
- `<TOTAL_AGENTS_LAUNCHED>` — count of baseline + fired conditional agents, minus the caller's `<EXCLUDE_AGENTS>` list. Used by the caller's report to phrase `<FAILED_AGENTS> of <TOTAL_AGENTS_LAUNCHED> agents failed`.

The caller formats and routes these per its mode (GitHub COMMENT / terminal output / fix application).
