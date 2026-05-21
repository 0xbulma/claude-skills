---
name: pr-switch
version: 1.0.0
description: Switch the local checkout to a GitHub PR's head branch. Accepts a PR URL, `owner/repo#num` shorthand, or a bare PR number; verifies the PR belongs to the current repo; resolves a dirty tree interactively (stash/commit/discard/abort); checks out via `gh pr checkout`. Use when user says /local:pr-switch, "checkout this PR", "switch to this PR's branch", "check out a PR link", or "get me on the branch for this PR".
---

# /local:pr-switch — Switch to a PR's Branch

Light-touch verb: parse a GitHub PR reference, verify it belongs to the current repo, get the working tree to a safe state, and run `gh pr checkout`. Stops there — does not review, fix, or open anything.

## Usage

```
/local:pr-switch <pr-url-or-number>
```

## Examples

```
/local:pr-switch https://github.com/0xbulma/claude-skills/pull/1
/local:pr-switch 0xbulma/claude-skills#1
/local:pr-switch 1
```

## Arguments

`$ARGUMENTS` should contain one of:

- A full PR URL (`https://github.com/<owner>/<repo>/pull/<num>`, with or without `/files`, `#…`, or query strings)
- `<owner>/<repo>#<num>` shorthand
- A bare PR number (assumes the current repo's `origin`)

If empty, ask: _"Which PR? Paste the URL or number."_

## Placeholders

| Placeholder | Source |
|---|---|
| `<OWNER>` / `<REPO>` | parsed from the argument; falls back to the current repo's `origin` for bare numbers |
| `<CUR_OWNER>` / `<CUR_REPO>` | parsed from `git remote get-url origin` |
| `<PR_NUMBER>` | parsed from the argument |
| `<BASE_BRANCH>` / `<HEAD_BRANCH>` | `gh pr view` → `baseRefName` / `headRefName` |
| `<HEAD_SHA>` | `gh pr view` → `headRefOid`; short = first 7 chars |

## Step 1: Parse the argument

Extract `<OWNER>`, `<REPO>`, `<PR_NUMBER>` from `$ARGUMENTS`:

- **URL** — match `github.com[:/]<owner>/<repo>/pull/<num>` (allow trailing `/files`, `/commits`, `#…`, `?…`).
- **Shorthand** — match `<owner>/<repo>#<num>`.
- **Bare number** — `^[0-9]+$` → leave `<OWNER>` / `<REPO>` empty (filled in Step 2).
- **Anything else** — report what you saw and ask the user for a valid form.

**Then validate `<PR_NUMBER>` against `^[0-9]+$` regardless of which path produced it** — the URL and shorthand regexes can yield non-numeric captures on malformed input, and `<PR_NUMBER>` flows directly into the shell snippets in Steps 4–7 and into the stash message in Step 5. If validation fails, refuse and ask for a valid form.

## Step 2: Detect the current repo

```bash
git remote get-url origin
```

Parse `<CUR_OWNER>/<CUR_REPO>` (strip `.git`, handle both `git@github.com:o/r.git` and `https://github.com/o/r.git`). If `git` isn't available or there's no `origin`, abort and tell the user they need to be inside a GitHub-backed git repo.

If `<OWNER>` / `<REPO>` were not parsed in Step 1 (bare number), set them to `<CUR_OWNER>` / `<CUR_REPO>`.

## Step 3: Cross-repo guard

If `<OWNER>/<REPO>` ≠ `<CUR_OWNER>/<CUR_REPO>`, **refuse**:

```
The PR you gave me lives in <OWNER>/<REPO>, but this working directory is <CUR_OWNER>/<CUR_REPO>.
Open the right workspace (cd into a clone of <OWNER>/<REPO>) and re-run me there.
```

Do not clone, do not `cd`, do not attempt `gh pr checkout` anyway. Stop.

## Step 4: Fetch PR metadata

```bash
gh pr view <PR_NUMBER> --json title,baseRefName,headRefName,headRefOid,state,isCrossRepository,headRepository,author,url
```

**Check the exit code.** If `gh pr view` exits non-zero (auth missing, network down, PR not found, repo is private without access), do not proceed — surface gh's stderr to the user verbatim and stop. Do not run Step 5 or Step 6 with empty/undefined placeholders.

If `state` is `MERGED` or `CLOSED`, surface the state and ask the user whether to continue — the branch may still be inspectable, but they probably meant a different PR.

## Step 5: Clean-tree check (interactive)

```bash
git status --porcelain
```

If output is non-empty, **show the user a 4-way choice**. Wait for their answer before doing anything else:

- **Stash** — run `git stash push -u -m "pr-switch: auto-stash before checkout of PR #<PR_NUMBER>"`. **Check the exit code**; if non-zero (e.g. rebase/merge in progress, partial index, detached HEAD edge case), abort the skill — do NOT proceed to Step 6, because `gh pr checkout` would otherwise clobber the still-dirty tree. After a successful checkout, remind the user of the stash message so they can `git stash list` / `git stash pop` later.
- **Commit** — abort the skill cleanly with: _"Commit your changes, then re-run `/local:pr-switch <PR_NUMBER>`."_ Don't try to commit for them.
- **Discard** — only after explicit confirmation (a second yes/no): resolve the repo root into a variable and **verify it's non-empty before `cd`** (an empty subshell result would `cd ""` → `$HOME` and run the destructive commands against an unrelated tree):

  ```bash
  REPO_ROOT="$(git rev-parse --show-toplevel)" && [ -n "$REPO_ROOT" ] || { echo "pr-switch: cannot resolve repo root; aborting Discard" >&2; exit 1; }
  cd "$REPO_ROOT"
  ```

  Then run `git checkout -- .`, **check its exit code** (interrupted merges leave unmerged paths that this command can't restore — if non-zero, surface the error and stop **before** running `git clean -fd`), and finally run `git clean -fd` to remove untracked files. Warn this is destructive and that untracked files will be lost. If the user wavers, default to Abort.
- **Abort** — stop, change nothing.

If the tree is clean, skip the prompt and go straight to Step 6.

## Step 6: Checkout the PR branch

```bash
git fetch origin
gh pr checkout <PR_NUMBER>
```

`gh pr checkout` handles fork PRs via the `isCrossRepository` metadata — no special-casing needed.

**Check the exit code of `gh pr checkout`.** Common failure modes — local branch already exists with divergent commits, fork-checkout permission error, dirty submodules, mid-fetch network drop — leave the working tree in a half-switched state. On failure:

1. Surface gh's stderr to the user verbatim.
2. If Step 5 stashed, tell the user the stash is intact (do not auto-`stash pop` — the tree may be in an inconsistent state).
3. Stop. Do NOT proceed to Step 7 or print a "Switched to PR #N" summary.

## Step 7: Report

After checkout, compute the ahead/behind counts vs. the base branch:

```bash
git fetch origin <BASE_BRANCH>
git rev-list --left-right --count origin/<BASE_BRANCH>...HEAD
```

Then print a short summary to the user:

```
Switched to PR #<PR_NUMBER>: <title>
  URL:    <url>
  Branch: <HEAD_BRANCH>  (was on <previous-branch>)
  Base:   <BASE_BRANCH>  (<ahead> ahead, <behind> behind)
  Head:   <HEAD_SHA_SHORT> by @<author.login>

Next:
  /local:pr-review-local      — review locally before commenting
  /local:pr-fix <PR_NUMBER>   — apply review comments and resolve conflicts
```

If you stashed in Step 5, append:

```
Note: your previous changes are in `git stash` (message: "pr-switch: auto-stash before checkout of PR #<PR_NUMBER>").
Run `git stash pop` to restore them — but expect conflicts if the PR branch touches the same files.
```

Stop. Do not run a review, do not fetch comments, do not open files.

## Notes

- This skill only switches branches. It does not pull updates if the local branch already exists and is behind — `gh pr checkout` handles that. If the user needs to resync explicitly later, that's `/local:pr-fix` territory.
- Never bypass the dirty-tree check by stashing silently — losing work to an unexpected stash is the kind of footgun this skill exists to avoid.
- The cross-repo guard is intentionally strict: this plugin's PR family assumes "the PR is in this repo." If you want to look at a PR in another repo, open that repo's workspace.
