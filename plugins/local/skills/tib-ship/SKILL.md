---
name: tib-ship
version: 0.2.0
description: Execute a TIB end-to-end (yolo). Plans TIPs, branches, implements per-block test-driven (format → lint → typecheck → test → commit per phase), then loops `pr-review-local` → fix → re-review until the branch is clean (max 5 iterations). Runs the `runtime-validation` persona if UI surfaces changed. Stops short of pushing — the user creates the PR. Use when user says /local:tib-ship, "ship this TIB", "yolo this TIB", "implement and self-review", or "execute the TIB end to end".
---

# /local:tib-ship — Execute a TIB End-to-End (Yolo)

Given a TIB, do everything between *decision* and *ready-to-push branch*: scaffold TIPs from the TIB's Implementation Phases, branch, implement each TIP, then run a tight `review → fix → review` loop locally until findings are clean. If the diff touches UI surfaces, run the `runtime-validation` persona to confirm the change actually works in a browser. Stops with a clean local branch and prints next-step instructions — does not push or open a PR.

> **Yolo means autonomous, not careless.** The skill stops and asks the user when it detects ambiguity, conflicting findings, or a stuck review loop. It will not bulldoze through unrelated dirty changes or pre-existing test failures.

## Arguments

`$ARGUMENTS` accepts:

- `<tib-path>` — required. Path to an accepted TIB markdown file.
- `--max-iters <N>` — optional, default `5`. Maximum review→fix cycles before bailing.
- `--phase <name>` — optional, repeatable. Only ship the named TIB Implementation Phase(s) instead of all.
- `--no-runtime` — optional. Skip the `runtime-validation` step even if UI surfaces changed.

If `<tib-path>` is empty or the file does not exist, abort with a clear error.

## Pre-flight gates (stop-and-ask)

Before doing anything destructive, check and abort with a clear message if any are true:

1. **Dirty working tree** — `git status --porcelain` non-empty. Ask the user to stash/commit first.
2. **Detached HEAD** — refuse; require an explicit base branch.
3. **TIB Status is not `Accepted`** — ask before proceeding (TIBs in `Proposed` should be reviewed first).
4. **Target branch already exists** — ask whether to reuse, replace, or pick a different name.
5. **Tests currently failing on the base branch** — run `<TEST_CMD>` once; if it fails, ask whether to proceed (yolo shouldn't paper over pre-existing breakage).

## Steps

### Step 1: Parse the TIB

1. Read the TIB at `<tib-path>`.
2. Extract:
   - **TIB-ID** (e.g. `TIB-2026-05-12`) from the H1.
   - **Title** from the H1 (after the colon).
   - **Implementation Phases** — bullet list under `### Implementation Phases`. If absent, treat the whole TIB as a single phase named after the title.
3. If `--phase <name>` was given (possibly repeated), filter to those phases. If a name does not match, abort.

### Step 2: Scaffold TIPs (one per phase)

For each selected phase, invoke `tip-create` as a sub-command:

```
/local:tip-create "<TIB-Title> — <Phase name>" --tib <tib-path>
```

This produces one TIP per phase, all back-linked via the `Sibling TIP(s)` mechanism (because they cite the same parent TIB). Capture the list of created TIP file paths as `TIP_PATHS`.

### Step 3: Create a feature branch

Branch name: `tib-ship/<TIB-ID>-<kebab-title>` (truncate kebab title to ~40 chars). If a custom name is needed, ask.

```bash
BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)
git fetch origin "$BASE" --quiet
git checkout -b "tib-ship/<TIB-ID>-<slug>" "origin/$BASE"
```

### Step 4: Implement each TIP (test-driven, per-block loop)

For each TIP in `TIP_PATHS`, in declaration order, walk its **Implementation Steps** phase-by-phase. **Each phase is a closed block — finish all six block-loop steps before starting the next phase.**

First, sniff the project's commands once per TIP using the same logic as `tip-create` Step 5:

- `<FORMAT_CMD>`, `<LINT_CMD>`, `<TYPECHECK_CMD>`, `<TEST_CMD>` from `package.json` scripts (with biome/prettier fallback for format, and `<exec>` choice — `pnpm exec` / `yarn exec` / `npx` / `bunx` — by lockfile).
- If a command is unresolvable (no `package.json`, no script, no formatter dep), skip that block-loop step but log a warning. Do not invent a command.

#### Load stack rubric (implementation parity with review)

Before spawning an implementation sub-agent for a TIP, compute the same `HAS_REACT` / `HAS_TAILWIND` / `HAS_STYLING` / `HAS_AI_SDK` / `HAS_WEB3` / `HAS_WORKFLOWS` / `HAS_RELEASE` / `HAS_DEPS` flags described in `skills/pr-review-engine/SKILL.md` Step 4 — but over the TIP's *declared* Files-to-Modify set (anticipated diff) rather than the actual diff. For every flag that's true, attach the corresponding marketplace skill bodies to the sub-agent's prompt so the implementation is written to the same rubric the review will then check against. Discovery is identical to the agent side — run-time `find ~/.claude -type f -name SKILL.md -path "*<skill-name>*" 2>/dev/null | head -1` per skill:

| Flag                              | Rubric skills to load                                                                  |
| --------------------------------- | -------------------------------------------------------------------------------------- |
| `HAS_REACT`                       | `vercel-react-best-practices`, `vercel-composition-patterns`, `next-best-practices`, `next-cache-components`, `building-components` (+ `vercel-react-native-skills` if RN detected) |
| `HAS_TAILWIND` or `HAS_STYLING`   | `tailwind-design-system`, `web-design-guidelines`, `building-components`               |
| `HAS_AI_SDK`                      | `ai-sdk`, `ai-elements`, `streamdown`                                                  |
| `HAS_WORKFLOWS`                   | `github-actions-docs`, `turborepo`                                                     |
| `HAS_RELEASE`                     | `deploy-to-vercel`, `vercel-cli-with-tokens`                                           |
| `HAS_DEPS`                        | (no marketplace skill — `dependencies` agent body is the rubric)                       |
| `HAS_WEB3`                        | (no marketplace skill — the `web3` agent body acts as both review and implementation rubric)         |

Skills absent from `~/.claude/skills/` are skipped silently (the implementation sub-agent falls back to its general knowledge). This mirrors the persona side's degrade-gracefully behavior. The goal is implementation/review parity: writing to the same rubric that will judge the work avoids predictable review-loop iterations.

#### Block loop (per phase)

For each phase the TIP declares:

1. **Tests first (red).** Read the phase's `Tests gating this phase` checkboxes. For each, create or extend the cited test file with assertions that fail meaningfully against the current code. Run only the targeted test file:
   ```
   <TEST_CMD> -- <test-file>     # or the equivalent runner-specific filter
   ```
   Confirm the new test fails for the *expected* reason (not e.g. an import error). If it passes already → either the gating test is too weak, or the change is already done; surface and ask.
2. **Implement (green).** Apply the phase's `Implementation` checkboxes in order:
   - Read the target file.
   - Apply the smallest edit that drives the gating tests toward green.
   - Tick the checkbox in the TIP (`[ ]` → `[x]`).
3. **Format.** Run `<FORMAT_CMD>` (auto-applies). Treat its output as authoritative — do not undo its changes.
4. **Lint.** Run `<LINT_CMD>`. If it supports auto-fix (most do), apply it. Surface any remaining warnings as in-block findings and fix them inline. Hard errors that you cannot fix in ≤2 attempts → bail this block and surface to Step 5's loop.
5. **Typecheck.** Run `<TYPECHECK_CMD>`. Errors → fix inline, ≤2 attempts. After 2 unsuccessful attempts, bail this block; the residue becomes input to Step 5's review/fix loop.
6. **Tests.** Run `<TEST_CMD>` scoped to the test files added/touched in step 1, plus the suite for the modified package(s). Must be green. If red after ≤2 fix attempts, bail this block; do not commit.
7. **Commit** (only when 3–6 are all green):
   ```
   feat(<scope>): <phase name>

   TIP: <relative-path-to-tip>
   TIB: <TIB-ID>
   ```
   Scope is derived from the package path of the first modified file (`packages/foo/...` → `foo`). If no package layout, omit the scope. Tick the `Block validation` checkboxes in the TIP.

#### Per-block retry budget

Inside a single block: ≤2 retry attempts per failing step (format → lint → typecheck → test). If a step is still failing after the budget, do not enter an infinite loop and do not silently skip — bail the block, record the residue as a Step-5 finding, and move to the next phase. Step 5's review/fix loop is the broader catch.

#### Parallelism

If multiple TIPs touch disjoint file sets, run them as parallel sub-agents (one per TIP). If their `Files to Modify` lists intersect, run sequentially in TIP order. Detect this by reading the Files-to-Modify tables before spawning. Each sub-agent runs the full block loop above for its TIP — they do not skip TDD just because they're running in parallel.

#### Status updates

After all phases for a TIP are green, set the TIP `Status` row from `Draft` to `In Progress`.

#### Stop-and-ask conditions during Step 4

- A TIP's Implementation Steps reference a file path that does not exist and the change is not "create new file" — surface and ask.
- Two TIPs propose conflicting changes to the same line — surface and ask.
- A single phase requires more than ~20 edits in unrelated files — likely a scoping problem; surface and ask before plunging in.
- A phase declares zero gating tests **and** the diff includes new production logic (not pure renames / docs / config) — TDD contract violated; surface and ask whether to (a) add gating tests now or (b) explicitly mark this phase `kind: no-tdd` with a one-line justification.

### Step 5: Review → fix loop

`MAX_ITERS = $ARGUMENTS --max-iters` (default 5). `prev_findings_hash = ""`.

For `i = 1..MAX_ITERS`:

1. Run the equivalent of `/local:pr-review-local` (delegate to `skills/pr-review-engine/SKILL.md` with `<DIFF_SOURCE>=local` and `<EXCLUDE_AGENTS>=["runtime-validation"]`). The exclusion prevents the dev server from booting once per iteration — Step 6 runs `runtime-validation` exactly once after the static loop converges. Do **not** pass `--fix`; we handle fixes ourselves so we can track convergence.
2. Collect findings into a list. If empty → **break, success**.
3. Compute a stable hash of the findings (sort by `file`, `line`, `description`; hash). If `hash == prev_findings_hash`:
   - Same findings as last iteration → **stuck**. Stop and ask the user (do not silently retry).
4. Group findings by severity. Apply fixes in this order: `critical` → `high` → `medium`. Skip `low` unless `<LOW_FIXES>` is requested.
5. For each finding:
   - Read the file at the cited line.
   - Apply the smallest change that addresses the finding's `description`.
   - If the finding is ambiguous or requires more than a localized edit (e.g. "refactor this module"), skip it and mark for the next iteration; do not invent large changes.
6. **Re-run the full block gate** after the fix batch, in this order: `<FORMAT_CMD>` → `<LINT_CMD>` → `<TYPECHECK_CMD>` → `<TEST_CMD>`. Any non-green gate becomes additional synthetic findings for the next iteration (do not commit broken state). The format step is allowed to mutate files freely; the others must be clean.
7. Commit the fixes (only when the gate is green):
   ```
   fix(review): iteration <i> — <N> findings

   TIB: <TIB-ID>
   ```
8. Set `prev_findings_hash = hash`. Continue.

If `i == MAX_ITERS` and findings are still non-empty → **bail**. Print the residual findings and ask the user whether to extend iterations, accept-and-continue, or stop.

### Step 6: Runtime validation (post-convergence, single shot)

After Step 5 converges, compute `<HAS_ROUTE_UI>` (see `skills/pr-review-engine/SKILL.md` Step 4 — route/page/layout/api-route/SPA-entry change + repo has a dev-server script). If `<HAS_ROUTE_UI>` is true AND `--no-runtime` was not passed, fire the `runtime-validation` persona exactly once:

1. Read `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/runtime-validation.md`.
2. Launch a single Agent (subagent_type: `general-purpose`) with the persona body as its prompt, the cumulative diff, the changed-files list, and the project's dev-server command.
3. Consume the agent's findings (same JSON shape as the review personas).
4. If any `critical` or `high` findings:
   - Treat them as one extra round of findings and re-enter Step 5 with **+1 iteration budget** (single extra pass for runtime fixes).
   - After that extra pass, re-run `runtime-validation` once. If it's still red → stop and surface to the user.

If `--no-runtime` was passed, or `<HAS_ROUTE_UI>` is false, print a note that runtime validation was skipped (and why).

Note: the static review loop in Step 5 already excludes `runtime-validation` from the parallel persona launch, so the dev server is booted at most twice end-to-end (once here, and once more if the first run produced findings that needed a re-pass).

### Step 7: Summary and stop

Print:

```
tib-ship complete: <TIB-ID>

Branch:           <branch>
TIPs created:     <count> at <relative paths>
Phases shipped:   <list>
Gating tests:     <new tests added> (added/extended across phases)
Block gates:      format ✓  lint ✓  typecheck ✓  tests ✓   (per-phase, end state)
Review iters:     <i> (clean on iteration <i>)
Runtime check:    passed | skipped | failed-then-fixed
Commits:          <N> (<feat: …> ×K, <fix(review): …> ×M)

Local branch is ready. Next steps (manual):
  git push -u origin <branch>
  /local:pr-create
```

Do **not** push. Do **not** open a PR. Do **not** delete the TIPs (they stay as living docs).

### Important notes

- This skill is autonomous between the pre-flight gates and the final summary. It does not ask mid-flight unless one of the explicit stop-and-ask conditions trips.
- All commits are conventional (`feat(...)`, `fix(review): ...`). Signed if the repo's commit signing is configured.
- The skill respects the user's CLAUDE.md / AGENTS.md throughout (loaded once via the review base in every Step 5 iteration).
- The skill writes back to the TIP files (ticking checkboxes, moving `Status`) — that is intentional, TIPs are mutable working documents.
- The skill does not modify the TIB. TIBs are frozen.
- If anything in the pre-flight, stop-and-ask, or stuck-loop conditions trips, the skill stops cleanly with a clear message. It does not silently retry or roll back commits already made — the user is in charge of cleanup.
