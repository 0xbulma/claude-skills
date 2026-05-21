---
name: pr-review-engine
version: 0.2.0
description: Run a parallel multi-lens review of the current diff. Invoked by other skills (pr-review-gh, pr-review-local, pr-fix, tib-ship), not by the user. Walks agents/, decides which apply via diff path patterns and dependency markers, fans out one sub-agent per match, aggregates findings. Replaces the previous lib/pr-review-base.md dispatcher with a real Anthropic-pattern skill (mirrors anthropics/skills/skills/skill-creator).
compatibility: Claude Code only. Uses `disable-model-invocation` (Claude Code-specific frontmatter) to keep the engine invisible to the model's slash-command surface — not portable to Claude.ai or the Messages API.
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
deduplicated findings list + `FAILED_AGENTS` count produced by Step 6.

## Success criteria

How a caller knows the engine is working (rough targets, not hard thresholds):

- **Triggering precision** — CI-only diffs fire `ci-security` and not `release-integrity` / `dependencies`; React-only diffs fire `react-next` and not `web3`. Verify via the per-fixture tests under `test/fixtures/`.
- **False-positive ceiling** — ≤ 10% of agent findings dropped by the scope filter on a healthy diff. If consistently higher, the diff path normalization or `CHANGED_LINES` build is wrong.
- **0 failed agents on a clean diff** — `FAILED_AGENTS` is empty when every agent's JSON parses and matches the WHAT/FIX schema. If non-zero, check schema injection in Step 5.
- **Bounded cost** — typical review fans out 6 baseline + 0–9 conditional agents. The mean token budget per agent is set by the sub-agent prompt envelope size + per-file content; a single review should cost no more than a non-trivial chat turn would.

## Inputs (from caller's Steps 1–2)

| Caller-provided | Source |
|---|---|
| `OWNER`, `REPO` | parsed from git remote |
| `HEAD_BRANCH` | `gh pr view` → `headRefName` (PR mode) OR `git branch --show-current` (Local) |
| `BASE_BRANCH` | `gh pr view` → `baseRefName` (PR mode) OR auto-detected default branch (Local) |
| `HEAD_SHA` | `gh pr view` → `headRefOid` (PR mode) OR `git rev-parse HEAD` (Local) |
| `DIFF_SOURCE` | `pr` (use `origin/BASE...origin/HEAD`) OR `local` (use `origin/BASE...HEAD` and overlay uncommitted) |
| `HEAD_REF` | `origin/HEAD_BRANCH` for `DIFF_SOURCE=pr`, `HEAD` for `DIFF_SOURCE=local` |
| `EXCLUDE_AGENTS` | Optional list of agent names to skip in Step 5 (e.g. `["runtime-validation"]` from `tib-ship` during iterations). Defaults to empty. |

Note on placeholder syntax: throughout this document, identifiers like `HEAD_REF` or `CHANGED_LINES` in code blocks and tables are template variables the caller fills in. They are deliberately written without `< >` brackets to keep the frontmatter and YAML elsewhere in the plugin free of XML angle brackets (per the Anthropic Skills guide, `< >` are forbidden inside frontmatter).

## Step 3: Get the diff locally

**Use the local repo on disk, NOT the GitHub API.**

Compute the merge-base and the diff:

```bash
MERGE_BASE=$(git merge-base origin/${BASE_BRANCH} ${HEAD_REF})

git diff $MERGE_BASE..${HEAD_REF}
git diff --name-only $MERGE_BASE..${HEAD_REF}

# Build the per-file changed-lines map. Used by Step 6 to drop findings whose
# cited line lies far outside any line the diff actually touched.
git diff --unified=0 $MERGE_BASE..${HEAD_REF}
```

Build `CHANGED_LINES` as a map `{ "<file-path>": <sorted-int-set> }` by parsing the unified=0 hunk headers. The deterministic implementation ships as a bundled script — prefer it over re-implementing the parser by hand:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/scripts/build-changed-lines.sh" \
  --base "$MERGE_BASE" --head "${HEAD_REF}" > /tmp/changed-lines.json
```

Edge-case handling (deletion-only hunks, pure renames) lives in `references/changed-lines.md`. Read it before adjusting the build rule.

If `DIFF_SOURCE=local` AND uncommitted changes exist, also include them:

```bash
git diff HEAD                  # combined staged + unstaged
git diff --name-only HEAD
git diff --unified=0 HEAD      # extend CHANGED_LINES with uncommitted hunks
```

Combine the two file lists, deduplicate, announce the count of uncommitted files included:

> "Including X uncommitted file(s) in the review."

If both diffs are empty, return an empty result to the caller (it will emit the appropriate "no changes to review" sentinel).

Read each changed file from the local filesystem using the Read tool so agents have full file context (not just diff hunks).

## Step 4: Read project context (adaptive)

Before launching review agents, read project-level documentation that defines the rules and intent of the repo. Store what you find as `PROJECT_CONTEXT` and pass it to each agent in Step 5.

### Always read (root-level baseline)

For each file below, read **only** if it exists. Prefer `AGENTS.md` over `CLAUDE.md` to avoid double-reading when one is a symlink to the other:

1. `AGENTS.md` (root). If absent, fall back to `CLAUDE.md` (root).
2. `MISSION.md` — mission, scope, and values (if present).
3. `CONTRIBUTING.md` — dev setup, contribution flow.
4. Lint/format contract: any of `biome.json`, `.eslintrc*`, `.oxlintrc.json`, `.prettierrc*`, `pyproject.toml`, `Cargo.toml`, `go.mod` — read whichever exist.

### Conditional baseline (read when relevant)

5. `SECURITY.md` — read if any security-relevant code is touched (auth, crypto, parsers, network entry points, secrets handling, onchain contract calls, wallet operations, CI / publish flow).
6. `docs/jsdoc-style.md` (or similar JSDoc / docstring style guide) — read whenever the diff touches an exported symbol with JSDoc.

### Per-package context (only for packages touched by the diff)

For each unique package directory among the changed files, read:

1. `<pkg>/AGENTS.md` — package-specific refinements (refines the root for this package; root wins on contradictions). If absent, fall back to `<pkg>/CLAUDE.md`.
2. `<pkg>/README.md` — public-facing description.
3. `<pkg>/ARCHITECTURE.md` — if present.
4. Any other top-level `*.md` in the package directory.
5. Nested `AGENTS.md` (or `CLAUDE.md`) along the path of touched files (at any depth).

Use the Glob tool: `**/AGENTS.md` and `**/CLAUDE.md`. Filter to paths that prefix at least one changed file's directory.

### Detect framework / domain signals (used by Step 5 conditional agents)

Compute boolean flags from the diff and from changed files' content. Flag names are bare (no `< >`); they're variable identifiers, not template placeholders:

- `HAS_WEB3` — true if any changed file imports a contract-interaction library (`viem`, `wagmi`, `ethers`, `web3.js`), contains contract address constants (`0x[a-fA-F0-9]{40}`), or contract interaction patterns (`useContractRead`, `useContractWrite`, `readContract`, `writeContract`, `simulateContract`, `signTypedData`, `permit*`).
- `HAS_REACT` — true if any changed file has extension `.jsx`/`.tsx`, OR imports `react`, `react-dom`, `next/*`, `@tanstack/react-*`, `@apollo/client`, OR contains `'use client'` / `'use server'` directives.
- `HAS_TAILWIND` — true if `HAS_REACT` AND any changed file contains a Tailwind-shaped class string in JSX (`flex`, `grid`, `p-N`, `m-N`, `text-`, `bg-`, `border-`, `rounded-`).
- `HAS_STYLING` — true if any changed file imports `styled-components`, `@emotion/*`, `tss-react`, `*.module.css`, `*.module.scss`, OR contains a11y attributes (`role=`, `aria-`, `tabIndex`).
- `HAS_WORKFLOWS` — true if any changed file matches `.github/workflows/**`, `.github/actions/**`, or `turbo.json`. Fires `ci-security`.
- `HAS_RELEASE` — true if any changed file matches `.changeset/**`, `vercel.json`, OR any `package.json` whose `scripts.*publish*` / `scripts.*release*` / `scripts.*deploy*` field is modified, OR any file containing `changeset publish`, `npm publish`, `pnpm publish`, `gh release create`, `vercel deploy`, or `vercel --prod`. Fires `release-integrity`.
- `HAS_DEPS` — true if any changed file matches `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `pnpm-workspace.yaml`, or `.npmrc` (any level). Fires `dependencies`.
- `HAS_AI_SDK` — true if any changed file imports `ai`, `@ai-sdk/*`, `@vercel/ai`, OR uses `streamText`, `generateText`, `streamObject`, `generateObject`, `embed`, `embedMany`, `useChat`, `useCompletion`, `useObject`, `ToolLoopAgent`, OR imports `ai-elements` or `streamdown`.
- `HAS_ROUTE_UI` — true if any changed file is **route-reachable**, i.e. a page/layout/api-route/SPA entry, AND the repo has a discoverable dev-server script. Intentionally narrower than `HAS_REACT` so we don't boot a dev server for arbitrary component changes. Matches:
  - **Next App Router:** `app/**/page.{tsx,jsx,ts,js}`, `app/**/layout.{tsx,jsx,ts,js}`, `app/**/template.{tsx,jsx}`, `app/**/loading.{tsx,jsx}`, `app/**/error.{tsx,jsx}`, `app/**/route.{ts,js}`.
  - **Next Pages Router:** `pages/**/*.{tsx,jsx,ts,js}` excluding `pages/_*.{tsx,jsx}`, `pages/api/**/*.{ts,js}`.
  - **SPA / Vite / Astro:** `src/pages/**/*.{tsx,jsx,astro,mdx}`, `src/routes/**/*.{tsx,jsx}`, `src/App.{tsx,jsx,ts,js}`, `src/main.{tsx,jsx,ts,js}`, `src/index.{tsx,jsx,ts,js}`, `index.html` at repo root.

  Component-only changes (e.g. `components/Button.tsx`) intentionally do **not** trigger this flag. Users who want runtime validation in that case should run `/local:tib-ship` (which always runs runtime-validation after convergence).

### Print discovery

After context discovery, print the list of files read and the flags so the user can spot omissions:

```
Context files read (N):
  AGENTS.md (root)
  CONTRIBUTING.md
  packages/foo/AGENTS.md
  ...

Conditional flags:
  Web3:           HAS_WEB3=<bool>
  React/Next:     HAS_REACT=<bool>
  Tailwind:       HAS_TAILWIND=<bool>
  Styling/a11y:   HAS_STYLING=<bool>
  Workflows:      HAS_WORKFLOWS=<bool>
  Release:        HAS_RELEASE=<bool>
  Dependencies:   HAS_DEPS=<bool>
  AI SDK:         HAS_AI_SDK=<bool>
  Route-UI:       HAS_ROUTE_UI=<bool>
```

## Step 5: Launch parallel review agents

Agent specs live in `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/*.md`. Each file has frontmatter declaring `kind: baseline` (always fires) or `kind: conditional` (fires only when its `trigger:` flag is true), plus the prompt body.

### Loop

1. Read every file in `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/*.md`.
2. For each agent, decide whether to launch:
   - `kind: baseline` → always launch.
   - `kind: conditional` → parse the `trigger:` value, look up each named flag from Step 4, evaluate the boolean expression. Compound triggers like `HAS_TAILWIND OR HAS_STYLING` are evaluated as written (split on whitespace, look up each flag, apply `OR` / `AND`).
3. **Apply the caller's exclusion list.** If the caller provided `EXCLUDE_AGENTS` (a list of agent names), drop those from the launch set. Used by orchestrators like `/local:tib-ship` to suppress an agent during inner iterations and run it once explicitly at the end (avoids paying dev-server boot N×, e.g. for `runtime-validation`).
4. Launch ALL selected agents **in parallel** using the Agent tool (subagent_type: `"general-purpose"`).
5. Track `TOTAL_AGENTS_LAUNCHED` = count of agents actually launched (baseline + any fired conditionals − excluded).

### Sub-agent prompt envelope (what the dispatcher must inject)

For every spawned sub-agent, the dispatcher **must** assemble the launch prompt from the following parts, in this order:

1. The agent file body, verbatim (its frontmatter + Markdown prose).
2. `PROJECT_CONTEXT` from Step 4 (root + per-package docs, lint contract).
3. The diff in full (committed + uncommitted when `DIFF_SOURCE=local`).
4. The full content of changed files (read from local FS via the Read tool).
5. The conditional flag values (`HAS_REACT`, `HAS_WEB3`, `HAS_WORKFLOWS`, etc.).
6. `CHANGED_LINES` serialized as JSON: `{ "<path>": [<line>, <line>, ...] }`.
7. **The "Shared per-agent contract" bullets below, copied verbatim into the prompt.** Without this injection, agents won't know to emit the schema and Step 6.2 will route every finding as malformed.
8. **The calibration example pair** (the kept-finding + dropped-finding pair below), copied verbatim. Anchors the agent's output shape.

The dispatcher should NOT paraphrase or summarize these parts — copy them. Drift between the dispatcher's notion of the contract and what the agent receives is exactly the failure mode the engine's schema check is supposed to prevent.

### Shared per-agent contract (applied uniformly to every launched agent)

- Each agent receives: full diff, full content of changed files, `PROJECT_CONTEXT` from Step 4, the conditional flag values, `CHANGED_LINES`, the agent file body, the repo path / branches.
- Per-package `AGENTS.md` rules refine the root for the specific package; the root wins on contradictions.
- Agents must analyze the **full diff**, not just the latest commit.
- Each agent **must return** a JSON array `[{severity: "critical"|"high"|"medium"|"low", file: "path", line: number, description: "WHAT: ... FIX: ..."}]` OR an explicit error sentinel `{"agent_error": "<reason>"}` if it could not complete.
- **`description` schema.** Every finding's `description` MUST contain both a `WHAT:` clause naming the specific problem AND a `FIX:` clause stating the specific change. Recommended format: `WHAT: <one sentence>. FIX: <one sentence>.` Free-form prose otherwise. Findings without both clauses are rejected as malformed in Step 6 sub-step 2.
- **`line` schema.** `line` must be a positive integer pointing at a line inside `CHANGED_LINES` for the cited `file`, OR within ±15 lines of one (the "adjacent code" tolerance window). Findings outside the window are dropped in Step 6 sub-step 1 as pre-existing. See `references/calibration.md` for the rationale behind ±15.
- **Stay in scope (avoid scope creep).** Focus on the diff: flag issues introduced by these changes, and issues in adjacent code only when the diff makes that adjacent code materially worse. Do NOT flag pre-existing issues, propose unrelated refactors, suggest new features, or recommend cleanups outside the PR's intent. When in doubt, omit.
- **Don't nitpick.** Polish, wording, naming preferences, stylistic alternatives, and "you could also" suggestions are not findings — omit them regardless of severity label.
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

This is kept because the `WHAT` clause names a specific problem at a specific line, the `FIX` clause is a concrete code change, the severity matches the agent's `severity-guidance:` (memory leak in a long-lived component → high), and the cited line is inside `CHANGED_LINES`.

A finding that would be **dropped** in Step 6 (bad shape):

```json
{
  "severity": "medium",
  "file": "src/components/SearchBox.tsx",
  "line": 42,
  "description": "Consider extracting this into a helper for readability."
}
```

This is dropped because: no `WHAT:` clause naming the specific problem, no `FIX:` clause stating the specific change, and the underlying suggestion is a stylistic preference — a textbook nitpick the master scope-guard prohibits.

### Current agent inventory

Baseline (always fire, 6 agents):

- `correctness.md` — type discipline, code smells, naming, security primitives, cross-file impact.
- `error-handling.md` — swallowed errors, missing error states, dead code paths.
- `docs.md` — JSDoc on exports + Markdown doc accuracy + pointer/link integrity.
- `tests.md` — missing tests, plus layout enforcement.
- `simplification.md` — unnecessary complexity, redundant logic, dead branches.
- `performance.md` — barrel imports, memory leaks, N+1, memoization correctness.

Conditional (fire only when their trigger flag is true, 9 agents):

- `web3.md` — fires when `HAS_WEB3`. Contract interactions, transaction params, permit flows, chainId validation.
- `react-next.md` — fires when `HAS_REACT`. Loads marketplace rubrics (see `references/marketplace-rubrics.md`).
- `styling.md` — fires when `HAS_TAILWIND OR HAS_STYLING`. Tailwind/tokens, styling-architecture consistency.
- `accessibility.md` — fires when `HAS_TAILWIND OR HAS_STYLING`. ARIA, keyboard, focus, alt text.
- `ci-security.md` — fires when `HAS_WORKFLOWS`. Workflow injection, action pinning, `permissions:` scopes, secret exposure.
- `release-integrity.md` — fires when `HAS_RELEASE`. Publish flow, provenance, release-commit signing, Changesets wiring.
- `dependencies.md` — fires when `HAS_DEPS`. Lockfile drift, dependency hygiene, `.npmrc`, typosquats.
- `ai-sdk.md` — fires when `HAS_AI_SDK`. Vercel AI SDK usage, streaming, tool calls, structured output.
- `runtime-validation.md` — fires when `HAS_ROUTE_UI`. Boots dev server, navigates changed routes, captures console errors / network 4xx-5xx / screenshots. Excluded by `/local:tib-ship` from its iteration loop.

The dispatcher does not hardcode names — it discovers via `find`. Total: 15 agents (6 baseline + 9 conditional).

Adding a new agent = drop a new file under `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/` with appropriate frontmatter. If conditional, also extend Step 4's flag detection.

## Step 6: Aggregate and deduplicate findings

Merge all agent results into a single list:

1. **Scope filter (drop out-of-scope findings).** Build `CHANGED_FILES` = the deduplicated file list from Step 3:
   - committed: `git diff --name-only $MERGE_BASE..${HEAD_REF}`
   - plus uncommitted: `git diff --name-only HEAD` (only when `DIFF_SOURCE=local`)

   For every agent finding, first guard `finding.file`: if it is missing, not a string, or empty, treat the finding as malformed and route it to sub-step 2's partial-failure handling instead of dropping it here. Otherwise, compare `finding.file` against `CHANGED_FILES` after path normalization (strip leading `./`, strip diff prefixes `a/` and `b/`, strip the repo-root prefix on absolute paths; case-sensitive compare to match git's default).

   If `finding.file` is not in `CHANGED_FILES`, **drop the finding** and increment `DROPPED_OUT_OF_SCOPE`.

   **Line-level scope filter (in-file).** For findings whose `file` IS in `CHANGED_FILES`, check `finding.line` against the file's `CHANGED_LINES` set built in Step 3. **Short-circuit:** if the file's set is empty (pure rename), skip the line-level filter for that file entirely. Otherwise:
   - If `finding.line` is in the set → keep.
   - If `finding.line` is outside the set but within ±15 lines of any changed line → keep (adjacent-code tolerance).
   - Otherwise → **drop** and increment `DROPPED_PRE_EXISTING`. The finding is tagged with `distance_to_nearest_changed_line` for audit purposes.

   The ±15 tolerance window is a fixed engine constant. See `references/calibration.md` for the rationale.

   **Markdown documentation-example filter.** Drop findings on `.md` files whose `description` matches secret/injection FP-suspect patterns AND whose cited line falls inside a fenced code block. The full rule (CommonMark fence handling, off-by-one, limitations) lives in `references/scope-filter.md`. Implementation ships as a script:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/scripts/validate-findings.py" \
     --findings findings.json --changed-lines /tmp/changed-lines.json
   ```

   The script emits the same `DROPPED_OUT_OF_SCOPE` / `DROPPED_PRE_EXISTING` / `DROPPED_DOC_EXAMPLE` counters as the inline rules above and tags each dropped finding with `drop_reason` plus, for line-level drops, `distance_to_nearest_changed_line`.

   After all three sub-filters, print one log line per counter that is non-zero:
   `Scope filter: dropped <N> file-level + <N> line-level + <N> doc-example finding(s).`

2. **Count agent failures.** An agent counts as failed if any of these hold:
   - Returned `{"agent_error": "..."}` (the explicit sentinel from Step 5).
   - Returned text that is not parseable as JSON.
   - Returned a JSON value that is not an array (e.g. an object that is not the error sentinel).
   - Returned an array containing one or more objects missing required fields:
     - `severity` not in `critical`/`high`/`medium`/`low`
     - missing or non-string `file`
     - missing or non-positive-integer `line`
     - missing or empty `description`
     - `description` lacks a `WHAT:` substring OR lacks a `FIX:` substring
     Count the agent as **partially failed**: keep the valid findings from that agent, but include it in `FAILED_AGENTS`.

   Track `FAILED_AGENTS` as a count plus the names. This count flows into the caller's Step 7 reporting so a "no findings" verdict is never reported when some agents crashed.

3. **Deduplicate** with this rule (do NOT collapse genuinely distinct findings):
   - Findings on the SAME file at the EXACT same line are duplicates ONLY when their descriptions overlap meaningfully (≥50% token overlap, or one is a clear paraphrase of the other). Keep the higher-severity one; if descriptions don't overlap, keep BOTH.
   - Findings within ±3 lines on the same file are merged ONLY when severities AND descriptions overlap.
   - When merging, keep the higher-severity finding's text.

4. Sort by: file path (alphabetical, ASC), then line number (ASC), then severity (DESC).

Severity labels:

- `critical` → Critical
- `high` → High
- `medium` → Medium
- `low` → Low

## Output contract (returned to caller)

The caller (Step 7 of `/local:pr-review-gh` / `/local:pr-review-local` / `/local:pr-fix` / `/local:tib-ship`) consumes:

- `FINDINGS` — sorted, deduplicated array of `{severity, file, line, description}`.
- `DROPPED_FINDINGS` — findings the scope filter dropped, each tagged with `drop_reason` (`file-out-of-scope` / `line-pre-existing` / `doc-example-fp`). Consumer skills render this as a collapsible audit section after the main findings list — never a silent nuke.
- `FAILED_AGENTS` — count + names of agents that returned `agent_error` or malformed output.
- `COUNTS` — `{critical, high, medium, low}` totals on the kept findings.
- `DROPPED_COUNTS` — `{out_of_scope, pre_existing, doc_example}` totals on the dropped findings.
- `TOTAL_AGENTS_LAUNCHED` — count of baseline + fired conditional agents, minus `EXCLUDE_AGENTS`.

The caller formats and routes these per its mode (GitHub COMMENT / terminal output / fix application). `pr-review-gh` and `pr-review-local` both surface `DROPPED_FINDINGS` as a collapsible "Audit trail" section in Step 7. `pr-fix` ignores `DROPPED_FINDINGS` (it operates on the kept findings only). `tib-ship` summarizes counters in its convergence log.

## Examples

### Example 1: PR-mode review of a CI-workflow-only change

Caller (`pr-review-gh`) hands in:
- `DIFF_SOURCE=pr`, `BASE_BRANCH=main`, `HEAD_BRANCH=feature/bump-checkout-action`
- Diff: a single file `.github/workflows/release.yml`, 2 changed lines.

Expected behavior:
- Step 4 sets `HAS_WORKFLOWS=true`; all other framework/domain flags false.
- Step 5 launches: 6 baseline + `ci-security` (only conditional whose trigger matches) = 7 agents in parallel. `release-integrity`, `dependencies`, `react-next`, `web3`, `ai-sdk`, `styling`, `accessibility`, `runtime-validation` are skipped.
- Step 6 aggregates findings; the CI agent typically owns 1–3 high-severity findings on action pinning / `permissions:`.

### Example 2: Local-mode review with uncommitted changes

Caller (`pr-review-local`) hands in:
- `DIFF_SOURCE=local`, `BASE_BRANCH=main`, `HEAD_REF=HEAD`
- Diff: 3 committed `.tsx` files + 2 uncommitted `.ts` files.

Expected behavior:
- Step 3 unions committed + uncommitted diffs, announces "Including 2 uncommitted file(s) in the review."
- Step 4 sets `HAS_REACT=true`; `HAS_TAILWIND` true if class strings detected.
- Step 5 fires 6 baseline + `react-next` + `styling` + `accessibility` = 9 agents.
- Step 6 produces a combined kept-findings list across the whole work-in-progress.

### Example 3: Excluding an agent in iteration loops (tib-ship)

Caller (`tib-ship`) hands in:
- `DIFF_SOURCE=local`, `EXCLUDE_AGENTS=["runtime-validation"]` during each inner iteration.

Expected behavior:
- Step 5.3 drops `runtime-validation` from the launch set so the dev server is not booted per iteration.
- `tib-ship` runs `runtime-validation` once explicitly after static convergence to pay the dev-server boot only once.

## Troubleshooting

### Symptom: every finding lands in `DROPPED_OUT_OF_SCOPE`

Likely path normalization disagreement. The agent returned absolute paths or paths with a `a/` prefix; the filter compares against git's `--name-only` output (relative, no prefix). Verify the normalization rules in Step 6 sub-step 1 cover the agent's actual output shape. If the diff is a pure rename, see the next symptom.

### Symptom: every finding on a renamed file is dropped

Pure renames produce empty `CHANGED_LINES` for the file. The line-level filter is supposed to short-circuit on an empty set — if findings are still being dropped, the build step (`scripts/build-changed-lines.sh`) may have produced a stale or partial JSON. Delete `/tmp/changed-lines.json` and rerun.

### Symptom: `FAILED_AGENTS` is non-empty but findings look fine

The agent returned valid findings but at least one is missing the `WHAT:` or `FIX:` clause. Run `scripts/validate-findings.py --findings <agent-output>.json --schema-only` to identify the offending finding. Common cause: the agent file body was not injected via the prompt envelope (Step 5), so the agent never saw the schema rule.

### Symptom: agent body talks about a deleted feature (e.g. `<MODE>=fix`)

The engine no longer carries a `MODE` input. `pr-fix` discovers fix-applicable agents via the bundled `scripts/list-fix-rubric-agents.sh` (any agent with a `## Fix rubric` section) — the dispatcher path is unused. If you see `<MODE>=fix` referenced anywhere, it's stale prose; remove it.

### Symptom: an obvious file is missing from `CHANGED_FILES`

Check `DIFF_SOURCE`. If `pr`, only committed changes count; uncommitted work-in-progress is invisible. Switch to `local` (or commit) to include uncommitted files.

### Symptom: too many findings dropped by the ±15 tolerance window

The window is a fixed engine constant. See `references/calibration.md` for the rationale.

## Bundled scripts

- `scripts/build-changed-lines.sh` — parses `git diff --unified=0` and emits the `CHANGED_LINES` JSON map. Handles deletion-only and pure-rename edge cases.
- `scripts/validate-findings.py` — applies the WHAT/FIX schema check + ±15 line-window filter + Markdown fenced-block detection. Emits dropped-findings with `drop_reason` and `distance_to_nearest_changed_line`.
- `scripts/list-fix-rubric-agents.sh` — discovers which agents carry a `## Fix rubric` section. Used by `pr-fix`'s rubric-loading loop and by the bats invariant test.

These exist so the deterministic logic isn't re-derived from English by every caller (per the Anthropic Skills guide, p. 26: "Code is deterministic; language interpretation isn't").

## References

- `references/changed-lines.md` — deletion-only and pure-rename edge cases for the `CHANGED_LINES` build.
- `references/scope-filter.md` — full rule for the Markdown documentation-example filter, including CommonMark fence handling and known limitations.
- `references/calibration.md` — rationale for the ±15 tolerance window and the `distance_to_nearest_changed_line` audit signal.
- `references/marketplace-rubrics.md` — inventory of marketplace skills loaded by individual agents.
- `references/secrets.md`, `references/injection.md`, `references/effect-cleanup.md` — shared rubric content cross-checked by multiple agents.
