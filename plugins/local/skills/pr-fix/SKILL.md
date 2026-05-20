---
name: pr-fix
version: 2.0.0
description: Apply fixes for PR review findings and resolve merge conflicts. Reads unresolved review comments from a pull request, applies the fixes locally, detects and resolves merge conflicts with the base branch, commits, pushes, and resolves the threads. Use when user says /local:pr-fix, "fix PR comments", "apply review fixes", "address PR feedback", or "fix conflicts". Takes a PR number as argument.
---

# PR Fix — Apply Review Findings & Resolve Conflicts

Apply fixes for unresolved PR review comments, resolve merge conflicts with the base branch, commit, push, resolve threads, and monitor CI. Optionally watches for new review comments and re-applies fixes automatically.

## Usage

```
/local:pr-fix <pr-number>
/local:pr-fix <pr-number> --watch
```

## Examples

```
/local:pr-fix 123
/local:pr-fix 456 --watch
```

## Arguments

`<PR_NUMBER>` — the pull request number in the current repository.

If no argument is provided, ask the user for the PR number.

> **TWO-PHASE SKILL**: Phase 1 (Steps 1-11) does the initial fix pass. Phase 2 (Step 12) creates a continuous watcher via CronCreate if `--watch` was passed. If `--watch` is used, the skill is NOT complete until Step 12's CronCreate call succeeds and you report the job ID to the user.

## Placeholder convention

Throughout this skill, the following placeholders are used consistently:

| Placeholder | Source | Description |
|---|---|---|
| `<OWNER>` | parsed from git remote | GitHub repo owner |
| `<REPO>` | parsed from git remote | GitHub repo name |
| `<PR_NUMBER>` | user argument | Pull request number |
| `<BASE_BRANCH>` | `gh pr view` → `baseRefName` | PR base branch |
| `<HEAD_BRANCH>` | `gh pr view` → `headRefName` | PR head branch |
| `<HEAD_SHA>` | `gh pr view` → `headRefOid` | Head commit full SHA |
| `<HEAD_SHA_SHORT>` | first 7 chars of `<HEAD_SHA>` | Head commit short SHA |
| `<REPO_PATH>` | `git rev-parse --show-toplevel` | Absolute path to repo root |

## Step 1: Detect Repository

Extract owner and repo from the git remote:

```bash
git remote get-url origin
```

Parse `<OWNER>` and `<REPO>` from the URL (handles both `git@github.com:owner/repo.git` and `https://github.com/owner/repo.git` formats). Strip the `.git` suffix.

## Step 2: Fetch PR Details and Checkout Branch

Use local `gh` CLI to get PR metadata (you are inside the repo already):

```bash
gh pr view <PR_NUMBER> --json title,baseRefName,headRefName,headRefOid,state
```

Extract:
- `<BASE_BRANCH>` — the base branch (`baseRefName`)
- `<HEAD_BRANCH>` — the head/PR branch (`headRefName`)
- `<HEAD_SHA>` — the head commit SHA (`headRefOid`)
- `state` — must be `OPEN`

If the PR is not open, inform the user and stop.

### 2a: Check for clean working tree

Before switching branches, verify the working tree is clean:

```bash
git status --porcelain
```

If there are uncommitted changes, warn the user and abort the skill entirely:
```
Working tree is not clean. Please commit or stash your changes before running /local:pr-fix.
```

### 2b: Fetch and checkout the PR branch

Use `gh pr checkout` which handles both existing and new local branches:

```bash
git fetch origin
gh pr checkout <PR_NUMBER>
```

This creates the local branch from the remote if needed, or switches to it if it already exists.

**Note:** This will leave you on the PR branch when the skill finishes. The original branch is not restored automatically.

## Step 3: Check and Resolve Merge Conflicts

### 3a: Check for merge conflicts with the base branch

```bash
# Check if the PR branch can be cleanly merged with the base branch
git merge --no-commit --no-ff origin/<BASE_BRANCH> 2>&1
```

### 3b: If there are no conflicts (or already up to date)

Abort the test merge only if one is active, then continue to Step 4:

```bash
# Only abort if MERGE_HEAD exists (a merge is in progress)
git rev-parse --verify MERGE_HEAD >/dev/null 2>&1 && git merge --abort || true
```

### 3c: If there are merge conflicts

The merge will report conflicting files. For each conflicting file:

1. **Read the file** with conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) using the Read tool
2. **Understand both sides**: The `HEAD` side is the PR branch changes, the `origin/<BASE_BRANCH>` side is the base branch changes
3. **Resolve the conflict** intelligently:
   - If the PR branch changes are newer/intentional, keep them
   - If the base branch introduced a necessary change (new import, renamed function, updated API), incorporate it
   - If both sides changed the same code for different reasons, merge both changes logically
   - Read surrounding files if needed to understand the intent of each side
4. **Edit the file** using the Edit tool to remove conflict markers and produce the correct merged result
5. **Validate the resolved file** — run any available linter/formatter on it (see Step 7 for detection)

After resolving all conflicts:

```bash
# Stage resolved files
git add <list of resolved files>

# Complete the merge
git commit -m "$(cat <<'EOF'
merge: resolve conflicts with <BASE_BRANCH>

Resolved merge conflicts in:
- <file1>
- <file2>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"

# Push the merge commit
git push origin <HEAD_BRANCH>
```

Print a summary of resolved conflicts:

```
Resolved merge conflicts with <BASE_BRANCH>:
  - <file1>: <brief description of resolution>
  - <file2>: <brief description of resolution>
```

### 3d: If conflicts cannot be resolved automatically

If a conflict is too ambiguous to resolve safely (e.g., both sides rewrote the same function entirely with different logic):

1. Abort the merge: `git merge --abort`
2. Inform the user which files have unresolvable conflicts and why
3. Continue with Step 4 (review comment fixes) — the conflicts will need human intervention

## Step 4: Collect Unresolved Review Comments

Use `gh api graphql` to fetch all review threads on the PR:

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            isOutdated
            comments(first: 50) {
              nodes {
                databaseId
                body
                path
                originalLine
                author { login }
              }
            }
          }
        }
      }
    }
  }' -f owner=<OWNER> -f repo=<REPO> -F pr=<PR_NUMBER>
```

**Note:** `reviewThreads(first: 100)` covers most PRs. If the PR has >100 review threads, re-query with the pagination cursor from `pageInfo { hasNextPage endCursor }` to fetch all threads.

**Filter to only unresolved, non-outdated threads** (`isResolved: false` AND `isOutdated: false`).

For each unresolved thread, extract:
- `threadId` — the GraphQL node ID (for resolving later)
- `path` — the file the comment is on
- `line` — the line number (`originalLine`)
- `body` — the comment text (contains the finding and suggestion); use the **most recent** comment in the thread (last in the `comments.nodes` array) as it may contain updated guidance
- `commentId` — the `databaseId` of the first comment (for replying)
- `author` — who posted the comment (to identify source: Claude, Codex, Copilot, or human)

Group findings by file for efficient fixing.

**Both Claude and Codex comments are handled.** Claude uses `**[SEVERITY]**` prefixes. Codex may use different formats (e.g., `severity:`, `[issue]`, or plain text). Parse both formats and normalize severity.

## Step 4.5: Read project context (adaptive)

Before triaging comments (Step 5) or applying any fixes (Step 6), read project-level documentation that defines the rules and intent of the repo. Store what you find as `<PROJECT_CONTEXT>` and use it to inform the severity parsing in Step 5d and the context-gathering in Step 6a.

### Always read (root-level baseline)

For each file below, read **only** if it exists. Prefer `AGENTS.md` over `CLAUDE.md` to avoid double-reading when one is a symlink to the other:

1. `AGENTS.md` (root). If absent, fall back to `CLAUDE.md` (root).
2. `MISSION.md` if present.
3. `CONTRIBUTING.md` if present.
4. Lint/format contract: any of `biome.json`, `.eslintrc*`, `.oxlintrc.json`, `.prettierrc*`, `pyproject.toml`, `Cargo.toml`, `go.mod` — read whichever exist.

### Conditional baseline (read when relevant)

5. `SECURITY.md` — read if any unresolved comment touches security-relevant code (auth, crypto, parsers, network entry points, secrets handling).
6. `docs/jsdoc-style.md` (or similar JSDoc style guide) — read whenever an unresolved comment touches an exported symbol with JSDoc.

### Per-package context (only for packages that have unresolved comments)

For each unique package directory among the files with unresolved comments, read:

1. `<pkg>/AGENTS.md` (or `<pkg>/CLAUDE.md` fallback) — package-specific refinements; root wins on contradictions.
2. `<pkg>/README.md`, `<pkg>/ARCHITECTURE.md` if present.
3. Nested `AGENTS.md` along the path of touched files (Glob `**/AGENTS.md`).

### Detect framework / domain signals

Detect from the codebase (not just the diff — fixes may need to read non-diff files):

- `<HAS_WEB3>` — true if any file in the repo (focus on files with unresolved comments and their imports) imports `viem`, `wagmi`, `ethers` (extend this union with any project-specific Web3 SDK imports — e.g. `@your-org/*`), or contains contract address constants (`0x[a-fA-F0-9]{40}`) or contract interaction patterns (`useContractRead`, `useContractWrite`, `readContract`, `writeContract`, `simulateContract`).
- `<HAS_REACT>` — true if any file with an unresolved comment has extension `.jsx`/`.tsx`, OR imports `react`, `react-dom`, `next/*`, `@tanstack/react-*`, `@apollo/client`, OR contains `'use client'` / `'use server'` directives.
- `<HAS_TAILWIND>` — true if `<HAS_REACT>` AND any file with an unresolved comment contains a Tailwind-shaped class string in JSX.

### Print discovery

```
Context files read (N):
  AGENTS.md (root)
  packages/foo/AGENTS.md
  ...

Conditional flags:
  Web3: <HAS_WEB3>
  React/Next: <HAS_REACT>
  Tailwind: <HAS_TAILWIND>
```

## Step 5: Triage & Relevance Assessment

**Do NOT blindly fix every unresolved comment.** Each comment must pass relevance assessment before being queued for fixing. This prevents wasted effort, incorrect fixes, and regressions from applying stale or misunderstood suggestions.

### 5a: Classify comment type

For each unresolved thread, classify the **most recent comment** into one of these categories:

| Category | Action | Examples |
|---|---|---|
| **Actionable fix** | Queue for fixing | "This should use `useMemo`", "Missing null check", "Add error boundary here" |
| **Question / Clarification** | Skip — reply acknowledging, leave unresolved | "Why was this approach chosen?", "Is this intentional?", "What happens if X?" |
| **Discussion / Opinion** | Skip — leave for human | "I'd prefer X over Y", "We should discuss whether...", "Not sure about this pattern" |
| **Praise / Acknowledgment** | Skip — resolve thread | "LGTM", "Nice refactor", "Good catch" |
| **Already addressed** | Skip — resolve with note | Comment refers to code that was changed in a subsequent commit |
| **Stale / Inapplicable** | Skip — reply explaining | Comment references code that no longer exists at that location |

**If classification is ambiguous, default to SKIP (leave for human review) rather than applying a potentially wrong fix.**

### 5b: Check code freshness

For each comment classified as "actionable fix," verify the referenced code still exists and is unchanged:

```bash
# Check if the file still exists
test -f <path>

# Check if the code around the commented line matches what the reviewer saw
# Read the file and compare the area around originalLine
```

Using the Read tool, read the file at `path` and examine the area around `originalLine`. If:
- The file no longer exists → classify as **Stale**
- The code at that line has significantly changed (different logic, moved elsewhere) → classify as **Stale** and search for where the code moved to; only re-classify as actionable if the same issue exists at the new location
- The code is substantially the same → proceed

### 5c: Check if already addressed

For each remaining actionable comment, check whether the issue was already fixed in a commit after the review:

```bash
# Get the date of the review comment to find commits after it
git log --oneline --since="<comment_created_date>" -- <path>
```

Read the current state of the code at the referenced location. If the specific issue described in the comment (e.g., missing null check, wrong hook usage) is **no longer present in the current code**, classify as **Already addressed**.

### 5d: Parse severity

For comments that passed 5a-5c as actionable, parse severity (case-insensitive):

- **Claude comments**: `**[CRITICAL]**`, `**[HIGH]**`, `**[MEDIUM]**`, `**[LOW]**` prefix format
- **Codex comments**: May use `severity:` fields, `[issue]`/`[suggestion]` tags, or plain text — infer severity from language (e.g., "bug", "security" → HIGH; "nit", "consider" → LOW)
- **Human comments**: Treat as HIGH by default unless they use language suggesting lower priority

Priority order:
1. **CRITICAL** — must fix
2. **HIGH** — must fix
3. **MEDIUM** — fix unless there's a good reason not to
4. **LOW** — fix if straightforward

### 5d.1: Web3 severity bump (when `<HAS_WEB3>` is true)

When `<HAS_WEB3>` is true (from Step 4.5), bump severity to **CRITICAL** for any comment whose target file or comment text matches:

- A contract address constant (`0x[a-fA-F0-9]{40}`).
- Hex calldata (`0x[a-fA-F0-9]{8,}`) outside an obvious test fixture.
- An import of `viem`, `wagmi`, `ethers`, or any project-specific Web3 SDK adjacent to the commented line.
- A contract interaction call (`readContract`, `writeContract`, `simulateContract`, `useContractRead`, `useContractWrite`, `signTypedData`, `permit*`).

Exception: if the comment language clearly says **"nit"**, **"consider"**, **"optional"**, or **"style"**, do NOT bump — keep the parsed severity. The bump is for substantive comments touching contract surface area.

This compensates for human reviewers under-tagging Web3 comments and ensures our confidence gate (Step 6b) takes them seriously.

### 5e: Print assessment summary

Print a summary to the user **before proceeding** — this gives them a chance to intervene:

```
PR #<PR_NUMBER> — Review Comment Assessment:

  Total unresolved threads: <N>
  Sources: X from Claude, Y from Codex, Z from humans

  Actionable fixes: <N>
    - <X> critical, <Y> high, <Z> medium, <W> low
  Skipped: <M>
    - <A> questions/discussions (leaving for human)
    - <B> stale/inapplicable (code changed)
    - <C> already addressed (will resolve)
    - <D> praise/acknowledgment (will resolve)

Proceeding with <N> actionable fixes...
```

## Step 6: Context Gathering & Fix Application

For each actionable finding (from Step 5), grouped by file:

### 6a: Gather context (MANDATORY — do this BEFORE attempting any fix)

For each file with findings, build a complete understanding:

1. **Read the full file** — Use the Read tool. Understand the overall structure, not just the flagged line.

2. **Read related files** — Identify and read files that are tightly coupled to the change:
   - Files imported by / importing the target file
   - Type definitions, interfaces, or schemas referenced at the flagged location
   - Parent components (if the fix is in a child component)
   - Test files for the target file (if they exist)
   - Callers of the function being modified (use Grep to find them: `grep -r "functionName" --include="*.ts"`)

   **You do NOT need to read every import** — focus on files directly relevant to the specific fix. For example, if the comment says "add a null check before calling `foo()`", read the definition of `foo` to understand what it returns and when it might be null.

3. **Understand the original intent** — Read the PR description and/or the commit that introduced the flagged code:
   ```bash
   git log --oneline -5 -- <path>
   git show <commit>:<path>  # if needed to understand what changed
   ```

4. **Check for downstream impact** — Before applying the fix, verify it won't break callers or dependents:
   ```bash
   # Find usages of the function/component/type being modified
   grep -rn "<symbol_being_changed>" --include="*.ts" --include="*.tsx"
   ```

5. **Conditional skill rubrics** — When the file under repair has framework/domain signals, additionally Read these skill files at run time and use their contents as part of the rubric for the confidence gate (Step 6b). Plugin-installed marketplace skills land in a versioned cache; discover the path via Bash before Reading:

   ```bash
   # Returns the first matching SKILL.md across the plugin cache and the legacy standalone skill dir.
   find_skill() { find ~/.claude -type f -name SKILL.md -path "*$1*" 2>/dev/null | head -1; }
   ```

   - **React/Next** (file is `.jsx`/`.tsx` or imports `react`/`react-dom`/`next/*`):
     - `REACT_RUBRIC=$(find_skill vercel-react-best-practices)`; if non-empty, Read `$REACT_RUBRIC`.
     - `COMP_RUBRIC=$(find_skill vercel-composition-patterns)`; if non-empty, Read `$COMP_RUBRIC`.
     - For each that loaded, print `Loaded conditional skill: <name>`. For each that resolved empty, print `Marketplace skill not found: <name> — degrading to inline rubric` and continue without that rubric.

   - **Tailwind** (file contains Tailwind-shaped class strings in JSX):
     - `TW_RUBRIC=$(find_skill tailwind-design-system)`; if non-empty, Read `$TW_RUBRIC` and print `Loaded conditional skill: tailwind-design-system`. If empty, log the degradation message and continue.

   - **Web3** (`<HAS_WEB3>` is true and file imports a contract-interaction library — `viem`, `wagmi`, `ethers`, or a project-specific web3 SDK — or contains contract addresses/calldata):
     - Re-read the Web3 portion of `<PROJECT_CONTEXT>` plus any `SECURITY.md` / `audits/*.md` discovered.
     - Use `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/web3-security.md` as the rubric for the confidence gate.

   - **CI / release files** (fix touches `.github/workflows/**`, `.github/actions/**`, `.changeset/**`, `pnpm-lock.yaml` / `package-lock.json` / `yarn.lock`, `pnpm-workspace.yaml`, `.npmrc`, or a `package.json` `scripts.*publish*` / `scripts.*release*` field):
     - If the target repo defines its own CI/release rules (look for a `Review automation` / `CI/release security` / `Release` section in the root `AGENTS.md` / `CLAUDE.md`, or a dedicated `docs/security/` / `SECURITY.md`), read that section first — it is authoritative.
     - Otherwise (or in addition) use the appropriate split rubric from `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/`:
       - `ci-security.md` for workflow injection, action pinning, `permissions:` scopes, secret exposure (when `.github/workflows/**` / `.github/actions/**` / `turbo.json` is the surface).
       - `release-integrity.md` for publish flow, provenance, release-commit signing, Changesets wiring (when `.changeset/**` / `vercel.json` / `scripts.*publish*|*release*|*deploy*` is the surface).
       - `dependencies.md` for lockfile drift, `.npmrc` hygiene, typosquats (when lockfiles / `.npmrc` / `pnpm-workspace.yaml` is the surface).

   - **Persona / spec-layering files** (fix touches `AGENTS.md` / `CLAUDE.md` itself, or any file under `.agents/personas/` / `.claude/agents/` / similar):
     - If the target repo uses a persona system (look for `.agents/personas/` or `.claude/agents/` and any `> Applied by personas: …` callouts in the spec), the bidirectional-backlink invariant applies: changes to a persona's `applies:` frontmatter must atomically update the corresponding callout in the spec, and vice versa. A one-sided fix is incomplete.
     - Use `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/documentation.md` (sections 3–4) as the rubric.

   These rubrics inform the confidence gate. Example: a comment saying "wrap this in `useMemo`" on code inside a Server Component is a HIGH→LOW confidence drop because the vercel-react-best-practices rubric flags `useMemo` as not applicable in Server Components — skip the fix and reply explaining why.

### 6b: Confidence gate

Before applying each fix, explicitly assess your confidence:

- **HIGH confidence** — You understand the code, the suggestion, the surrounding context, and the fix is straightforward. **Proceed.**
- **MEDIUM confidence** — The fix seems right but you're not 100% sure about side effects or the reviewer's full intent. **Proceed but flag in the thread reply** that the fix should be double-checked.
- **LOW confidence** — You don't fully understand the code, the suggestion is ambiguous, or the fix could have non-obvious side effects. **Skip the fix.** Reply to the thread explaining what's unclear and leave it unresolved for human review.

**Skill-rubric override**: If a conditional rubric loaded in 6a.5 directly contradicts the suggested fix (e.g., comment says "wrap this in `useMemo`" but the file is a Server Component per the vercel-react-best-practices rubric), drop confidence to LOW and skip with a reply citing the rubric. Same for Web3 fixes that would violate a `SECURITY.md` invariant.

**Never apply a fix you don't understand. A skipped finding is always better than a wrong fix.**

### 6c: Apply the fix

Use the Edit tool to make the change. Follow the suggestion in the review comment. If the comment describes a problem but not a specific fix, use the context gathered in 6a to implement the correct solution.

**Rules:**
- Fix only what the comment asks for — don't refactor surrounding code
- Preserve existing code style (indentation, naming conventions, etc.)
- If a fix requires changes across multiple files (e.g., updating an interface), make all necessary changes
- If a finding is about missing tests, write the test
- If a finding cannot be fixed (e.g., it's a false positive or disagrees with project conventions), skip it and note it for Step 9
- If applying the fix would contradict another unresolved comment on the same code, skip both and flag the conflict for human review

### 6d: Validate the fix

After each file is modified, run any available linters or formatters if the project has them:

```bash
# Detect and run project linters/formatters (examples)
# Node: npx eslint --fix <file> or npx prettier --write <file>
# Go: gofmt -w <file>
# Python: ruff format <file> or black <file>
# Rust: cargo fmt
# Terraform: terraform fmt <file>
```

Check if the project has a Makefile, package.json scripts, or similar — use whatever lint/format commands are available. If none exist, skip this sub-step.

## Step 7: Quality Gate

After all fixes are applied, run broader quality checks if available.

First, discover what quality commands the project provides by reading:
- `package.json` → `scripts` section (look for `lint`, `typecheck`, `check`, `test`, `build`)
- `Makefile` / `Justfile` → lint/check/test targets
- `pyproject.toml` / `Cargo.toml` / `go.mod` → language-specific tooling

Then run the relevant checks:

```bash
# Common patterns (use whatever the project provides):
# - Node/TS: npx tsc --noEmit, npm run lint, npm run typecheck
# - Go: go vet ./..., golangci-lint run
# - Python: mypy, ruff check
# - Rust: cargo check, cargo clippy
```

If errors are found, fix them before proceeding. If no quality commands are discoverable, skip this step.

## Step 8: Commit and Push

### 8a: Stage all changed files

```bash
git add <list of changed files>
```

Only stage files that were actually modified as part of the fixes.

Before committing, verify the staged set explicitly:

```bash
git diff --cached --name-only
```

If unrelated files are already staged (e.g., from a prior incomplete operation), unstage them first:

```bash
git reset HEAD <unrelated files>
```

Do not proceed until only fix-related files are staged.

### 8b: Create a single commit

Commit message format:

```bash
git commit -m "$(cat <<'EOF'
fix: address PR review findings

Applied fixes for <N> review comments:
- <brief summary of key fixes>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 8c: Push to remote

```bash
git push origin <HEAD_BRANCH>
```

## Step 9: Reply to and Resolve Review Threads

For each finding that was fixed:

### 9a: Reply to the comment thread

Use a heredoc or `$'...'` to ensure real newlines (not literal `\n`):

```bash
gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/comments \
  --method POST \
  -F in_reply_to=<commentId> \
  -f body="$(cat <<'REPLY_EOF'
> <abbreviated original comment>

Fixed in <commit_sha> — <brief description of what was changed>
REPLY_EOF
)"
```

### 9b: Resolve the thread

```bash
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }' -f threadId=<threadId>
```

### 9c: For skipped findings

If a finding was skipped (false positive, disagrees with conventions, etc.), reply explaining why it was not fixed, but do NOT resolve the thread — leave it for human review:

```bash
gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/comments \
  --method POST \
  -F in_reply_to=<commentId> \
  -f body="$(cat <<'REPLY_EOF'
> <abbreviated original comment>

Skipped — <reason why this was not fixed>. Leaving for human review.
REPLY_EOF
)"
```

## Step 9.5: Reconcile All Current Open Threads

Fetch unresolved, non-outdated review threads again and make sure **every** current thread is explicitly addressed before moving on:

- Fixed thread:
  - reply on that exact thread with the commit SHA
  - resolve the thread
- Skipped thread:
  - reply on that exact thread with the skip reason
  - leave the thread unresolved

Do not assume that replying to one duplicate comment is enough. If reviewers left the same finding on multiple lines/threads, reply to each thread individually.

Verification check:

- fetch current unresolved, non-outdated threads
- inspect the latest comment on each thread
- confirm each thread has either:
  - a fix reply plus a resolved state, or
  - a skip reply

Do not report success while any unresolved, non-outdated thread lacks either a fix reply + resolution or a skip reply.

## Step 10: Monitor CI After Push

After pushing the fix commit, check whether CI passes on the new commit.

### 10a: Wait briefly for CI to start

```bash
sleep 15
```

### 10b: Check CI status

```bash
gh pr checks <PR_NUMBER> --repo <OWNER>/<REPO>
```

### 10c: If CI is still running

Poll up to 5 times with 30-second intervals:

```bash
gh pr checks <PR_NUMBER> --repo <OWNER>/<REPO> --watch --fail-fast
```

If `--watch` is not available, poll manually:

```bash
# Poll loop (up to 5 attempts, 30s apart)
for i in 1 2 3 4 5; do
  PENDING=$(gh pr checks <PR_NUMBER> --repo <OWNER>/<REPO> --json name,bucket --jq '[.[] | select(.bucket == "pending")] | length')
  if [ "$PENDING" = "0" ]; then break; fi
  sleep 30
done
```

### 10d: If CI fails

1. Get the failed check details and extract the run ID:
   ```bash
   # Get failed checks
   gh pr checks <PR_NUMBER> --repo <OWNER>/<REPO> --json name,bucket,link --jq '.[] | select(.bucket == "fail")'

   # Extract run ID from the failed check's link URL
   RUN_ID=$(gh pr checks <PR_NUMBER> --repo <OWNER>/<REPO> --json bucket,link --jq '.[] | select(.bucket == "fail") | .link | capture("/runs/(?<id>[0-9]+)") | .id' | head -1)
   ```
2. Fetch the CI logs for the failed job:
   ```bash
   gh run view "$RUN_ID" --repo <OWNER>/<REPO> --log-failed
   ```
3. Analyze the failure and determine if it was caused by the fix commit.
4. If the failure is caused by the fix:
   - Apply a corrective fix
   - Stage, commit with message `fix: address CI failure from review fixes`
   - Push again
   - Re-check CI (repeat 10b-10d, max 2 retries to avoid infinite loops)
5. If the failure is pre-existing (not caused by the fix commit): note it in the report but don't try to fix it.

### 10e: If CI passes

Continue to Step 11.

## Step 11: Report to User

Print a final summary:

```
PR #<PR_NUMBER> fixes applied and pushed.

Commit: <HEAD_SHA_SHORT>
Conflicts: <RESOLVED X files / NONE / UNRESOLVABLE>
Fixed: <N> findings (X from Claude, Y from Codex, Z from humans)
Skipped: <M> findings (see thread replies for reasons)
CI: <PASS/FAIL/PENDING>

Resolved threads: <N>
Left open for human review: <M>

Note: You are now on branch <HEAD_BRANCH>.
```

If conflicts were resolved, list each file and the resolution strategy.
If conflicts could not be resolved, list the files and why.
If any findings were skipped, list them with the reason.
If CI failed on a pre-existing issue, note it separately.
Also state whether every current unresolved, non-outdated thread was addressed in the reconciliation pass.

If `--watch` was NOT passed, the skill is complete here.

If `--watch` WAS passed, **you MUST proceed to Step 12**.

## Step 12: Schedule Continuous Watch (only with --watch)

**If `--watch` was passed, you MUST call `CronCreate` now.** Do not skip this step.

Use `CronCreate` to schedule a recurring job every 2 minutes:

- cron: `*/2 * * * *`
- recurring: true
- prompt: The prompt below, with all `<PLACEHOLDERS>` replaced with actual values from Steps 1-2:

```
You are the PR fix watcher for PR #<PR_NUMBER> in <OWNER>/<REPO>.
Repo path: <REPO_PATH>
Head branch: <HEAD_BRANCH>
Base branch: <BASE_BRANCH>

This is a RECURRING cron job. Each run is one check cycle. After completing a cycle, simply end your response — the cron scheduler will invoke you again in 2 minutes.

CYCLE START:

1. CHECK PR STATE:
   Run: cd <REPO_PATH> && gh pr view <PR_NUMBER> --json state --jq '.state'
   If not "OPEN": say "PR #<PR_NUMBER> is no longer open (state: <STATE>). Fix watcher done." and end.

2. FETCH AND SYNC:
   Run: cd <REPO_PATH> && git fetch origin && gh pr checkout <PR_NUMBER>

3. CHECK MERGE CONFLICTS:
   Run: cd <REPO_PATH> && git merge --no-commit --no-ff origin/<BASE_BRANCH> 2>&1
   - If clean (or already up to date): run `git rev-parse --verify MERGE_HEAD >/dev/null 2>&1 && git merge --abort || true` and continue to step 4.
   - If conflicts: for each conflicting file, read it with the Read tool, resolve conflict markers using the Edit tool (keep PR changes if intentional, incorporate base changes if necessary, merge both logically). Then: `git add <resolved files>` and `git commit -m "merge: resolve conflicts with <BASE_BRANCH>"` and `git push origin <HEAD_BRANCH>`. Report resolved files.
   - If conflicts are too ambiguous: `git merge --abort`, report which files, continue to step 4.

4. CHECK CI:
   Run:
   cd <REPO_PATH> && gh pr checks <PR_NUMBER> --json name,bucket,link --jq '.[] | select(.bucket == "fail")'
   If CI failures exist:
   a. Extract run ID: RUN_ID=$(gh pr checks <PR_NUMBER> --json bucket,link --jq '.[] | select(.bucket == "fail") | .link | capture("/runs/(?<id>[0-9]+)") | .id' | head -1)
   b. Get logs: gh run view "$RUN_ID" --repo <OWNER>/<REPO> --log-failed
   c. If caused by a recent fix commit: apply corrective fix, commit "fix: address CI failure", push (max 2 retries)
   d. If pre-existing: note it, do not fix

5. FETCH UNRESOLVED REVIEW COMMENTS using gh api graphql:
   Run:
   gh api graphql -f query='
     query($owner: String!, $repo: String!, $pr: Int!) {
       repository(owner: $owner, name: $repo) {
         pullRequest(number: $pr) {
           reviewThreads(first: 100) {
             nodes {
               id
               isResolved
               isOutdated
               comments(first: 50) {
                 nodes {
                   databaseId
                   body
                   path
                   originalLine
                   author { login }
                 }
               }
             }
           }
         }
       }
     }' -f owner=<OWNER> -f repo=<REPO> -F pr=<PR_NUMBER>

   Filter to threads where isResolved=false AND isOutdated=false.
   For each thread: extract threadId (the node id), path, line (originalLine), body (use last comment in thread for latest guidance), commentId (databaseId of first comment), author.
   Parse severity case-insensitively from comment body.

6. EVALUATE:
   If zero unresolved comments AND CI passing AND no conflicts: say "PR #<PR_NUMBER> is green — no unresolved comments, CI passing, no conflicts." and end this cycle.

7. ASSESS RELEVANCE before fixing (DO NOT skip this):
   For each unresolved comment, determine if it is actually fixable:
   a. Classify: Is it an actionable fix request, a question/discussion, praise, or stale?
      - Questions ("why?", "is this intentional?"), discussions ("I'd prefer..."), and praise ("LGTM") are NOT actionable — skip them (reply acknowledging for questions, resolve for praise, leave discussions for humans).
   b. Check freshness: Read the file at the commented path+line. Does the referenced code still exist and match what the reviewer commented on? If the code has changed significantly, classify as stale — reply explaining the code has changed and leave for human review.
   c. Check if already addressed: Is the issue described in the comment already fixed in the current code? If yes, reply noting it's already addressed and resolve the thread.
   d. Confidence gate: For remaining actionable comments, read the file AND related files (imports, callers, type definitions) to build sufficient context. Only proceed with fixes where you have HIGH or MEDIUM confidence. For LOW confidence (ambiguous suggestion, unclear side effects, insufficient context), skip and reply explaining what's unclear.
   e. PROJECT CONTEXT (re-discover per cycle): Read AGENTS.md (or CLAUDE.md fallback) at root, plus per-package AGENTS.md walkup for files with unresolved comments. Compute conditional flags: HAS_WEB3 (viem/wagmi/ethers imports — extend per project with org-specific Web3 SDK imports — or contract address constants in commented files), HAS_REACT (.jsx/.tsx or react/next imports in commented files), HAS_TAILWIND (Tailwind class strings in JSX). When a flag is true and the file under repair matches, additionally discover and Read the marketplace rubric SKILL.md via Bash: `find ~/.claude -type f -name SKILL.md -path "*<skill-name>*" 2>/dev/null | head -1` for each of `vercel-react-best-practices`, `vercel-composition-patterns`, `tailwind-design-system`. If the path resolves non-empty, Read it and print "Loaded conditional skill: <name>"; otherwise print "Marketplace skill not found: <name> — degrading to inline rubric" and continue.
   f. WEB3 SEVERITY BUMP: When HAS_WEB3 and a comment touches contract addresses, hex calldata, or Web3 imports, bump severity to CRITICAL unless the comment language is "nit"/"consider"/"optional"/"style".

   **Never apply a fix you don't fully understand. A skipped finding is always better than a wrong fix.**

8. APPLY FIXES for comments that passed relevance assessment:
   a. Group by file. For each file: read the FULL file with Read tool, also read related files (imports, type definitions, callers) to understand context. Apply fix with Edit tool per the comment suggestion.
   b. Discover and run available project linters/formatters on modified files (read package.json scripts, Makefile, etc. to find the right commands).
   c. Stage: `git add <changed files>` (verify only fix-related files are staged with `git diff --cached --name-only`; unstage unrelated files with `git reset HEAD <file>` if needed)
   d. Commit using heredoc for proper newlines:
      git commit -m "$(cat <<'INNEREOF'
fix: address PR review findings

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
INNEREOF
)"
   e. Push: `git push origin <HEAD_BRANCH>`
   f. For each fixed comment, reply in-thread using a heredoc for proper newlines:
      gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/comments --method POST -F in_reply_to=<commentId> -f body="$(cat <<'REPLYEOF'
> <abbreviated comment>

Fixed in <sha>
REPLYEOF
)"
   g. Resolve each thread:
      gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<threadId>
   h. For skipped findings, reply with skip reason (using heredoc) but do NOT resolve the thread.
   i. Say "Assessed <N> comments: fixed <X>, skipped <Y> (questions/stale/low-confidence). Pushed commit <sha>, resolved <X> threads."

CYCLE END — the cron scheduler will run this again in 2 minutes.
```

**After CronCreate returns the job ID:**
1. Report the job ID to the user
2. Tell them they can cancel with `CronDelete` using that ID
3. Note that the watcher auto-expires after 3 days
4. Only THEN is the skill complete

## Error Handling

- If no unresolved review comments exist on first run: tell the user "No unresolved review comments found on PR #<PR_NUMBER>." but still schedule the watcher if `--watch` was passed (comments may appear later from reviewers)
- If checkout fails (dirty working tree): warn the user and suggest stashing or committing first
- If push fails (e.g., branch protection): inform the user with the error
- If a fix introduces a syntax error: revert that specific change and skip the finding
- If resolving a thread fails: log the error but continue with other threads
- If CI fix retries exceed 2 attempts: stop retrying, report the failure, and leave it for the user
- If CronCreate is not available: skip continuous monitoring, inform the user that `--watch` requires CronCreate

## Notes

- **Context-aware, not blind**: Every comment is assessed for relevance before fixing. Comments are classified (actionable vs. question vs. discussion vs. stale), checked for code freshness, and verified not already addressed. Fixes are only applied when the agent has sufficient context and confidence. Skipping is always preferred over a wrong fix.
- **Local-first**: All code reading and editing happens on the local filesystem. Only GitHub API is used for reading review comments (via GraphQL) and posting replies/resolving threads (write operations).
- **Handles all reviewers**: Picks up unresolved comments from Claude, Codex, Copilot, and human reviewers. Normalizes severity case-insensitively across different comment formats.
- **CI-aware**: Monitors CI after pushing fixes. Extracts run IDs from check URLs to fetch logs. Automatically diagnoses and fixes CI failures caused by the fix commit (up to 2 retries). Pre-existing CI failures are reported but not touched.
- **Conflict-aware**: Detects merge conflicts with the base branch before applying review fixes. Resolves conflicts intelligently by reading both sides and merging logically. Conflicts that can't be safely resolved are reported for human intervention.
- **Quality gates**: Discovers and runs project linters/formatters after each file fix and broader quality checks (typecheck, lint) after all fixes. Ensures fixes don't introduce new issues.
- **Self-contained watcher**: The cron watcher does actual work inline (resolves conflicts, applies fixes, replies to threads, resolves threads) rather than re-invoking the skill. This avoids recursive watcher creation and ensures each cron tick is a complete fix cycle. The watcher also performs relevance assessment on every cycle — it never blindly fixes.
- **Pairs with `/local:pr-review-gh`**: `/local:pr-review-gh` posts findings (from parallel Claude agents + optional Codex), `/local:pr-fix` applies fixes. With both using `--watch`, they form a fully autonomous review-fix loop.
- Fixes are applied to the PR branch, not main/dev
- One commit for all fixes — keeps the PR history clean
- Each reply includes the commit SHA for traceability
- Skipped findings are explicitly noted but left unresolved for humans
- The cron watcher auto-expires after 3 days per system limits
- The skill assumes it is invoked from within the git repository
