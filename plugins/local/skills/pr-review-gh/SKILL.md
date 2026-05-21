---
name: pr-review-gh
version: 2.0.0
description: Local PR review bot. Reviews an open pull request with parallel specialized agents (6 baseline + conditional Web3, React/Next, styling, accessibility, AI-SDK, CI-security, release-integrity, dependencies, route-UI) and posts findings as inline GitHub review comments using event=COMMENT (never auto-approves). Optionally watches for new commits and re-reviews. Use when user says /local:pr-review-gh, "review PR", "watch PR", or "babysit PR". Takes a PR number as argument.
---

# review-gh — Local PR Review (post to GitHub)

Reviews a GitHub Pull Request locally using parallel specialized agents from `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/SKILL.md`, posts findings as inline review comments with `event="COMMENT"`. Never auto-approves or requests changes — leaves the verdict to humans. Optionally schedules a 2-minute watcher cron via `--watch`.

## Usage

```
/local:pr-review-gh <PR_NUMBER>
/local:pr-review-gh <PR_NUMBER> --watch
```

## Pre-conditions

- A `<PR_NUMBER>` is required.
- The skill is local-only by design. If `CI=true` or `GITHUB_ACTIONS=true` is detected, print one warning line — `WARNING: local:pr-review-gh runs locally; this skill family does not ship a CI variant. Use the repo-level pr-review-ci instead if you need CI verdicts.` — and continue. Do not refuse.
- If `--watch` is passed, the skill is NOT complete until Step 9's CronCreate succeeds and the job ID is reported.

## Placeholder convention

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
| `<BOT_LOGIN>` | `gh api user --jq '.login'` | Current GitHub user's login (only needed for `--watch`) |

## Step 1: Validate environment + arguments

```bash
if [ -z "${1:-}" ]; then
  echo "local:pr-review-gh requires a PR number." >&2
  exit 1
fi
if [ "$CI" = "true" ] || [ "$GITHUB_ACTIONS" = "true" ]; then
  echo "WARNING: local:pr-review-gh runs locally; this skill family does not ship a CI variant. Use the repo-level pr-review-ci instead if you need CI verdicts." >&2
fi
```

Parse `<OWNER>` and `<REPO>` from `git remote get-url origin` (handles both `git@github.com:owner/repo.git` and `https://github.com/owner/repo.git`).

If `--watch` was passed, also capture `<BOT_LOGIN>=$(gh api user --jq '.login')` for use in Step 9.

## Step 2: Fetch PR details

```bash
PR_JSON=$(gh pr view <PR_NUMBER> --json title,body,baseRefName,headRefName,headRefOid,state 2>&1)
if [ $? -ne 0 ]; then
  echo "gh pr view <PR_NUMBER> failed: $PR_JSON" >&2
  exit 1
fi
```

Extract `<BASE_BRANCH>`, `<HEAD_BRANCH>`, `<HEAD_SHA>`, `state`. Validate that all three branch/SHA fields are non-empty AND not whitespace-only (use `[ -z "${X//[[:space:]]/}" ]` — bare `[ -z "$X" ]` lets whitespace pass). If `state` is not `OPEN`, inform the user and stop. Then `git fetch origin`.

## Steps 3–6: Shared review base

**Read `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/SKILL.md` and follow Steps 3–6 there**, with these inputs:

- `DIFF_SOURCE` = `pr`
- `HEAD_REF` = `origin/<HEAD_BRANCH>`

The base produces: `FINDINGS`, `DROPPED_FINDINGS`, `FAILED_AGENTS`, `COUNTS`, `DROPPED_COUNTS`, `TOTAL_AGENTS_LAUNCHED`.

## Step 7: Post the review as `COMMENT`

Build a JSON object at `/tmp/local:pr-review-gh-<PR_NUMBER>-comments.json`:

```json
{
  "commit_id": "<HEAD_SHA>",
  "event": "COMMENT",
  "body": "<REVIEW_BODY>",
  "comments": [
    {
      "path": "<file>",
      "line": <line_number>,
      "side": "RIGHT",
      "body": "**[SEVERITY]** <description>\n\nSuggestion: <how to fix>"
    }
  ]
}
```

Always use `"event": "COMMENT"` — never auto-approve or request changes.

### Body format

```
## Parallel PR Review (Claude — local:pr-review-gh)

**Reviewed commit:** `<HEAD_SHA_SHORT>`

| Severity | Count |
|----------|-------|
| Critical | X |
| High | X |
| Medium | X |
| Low | X |

<details>
<summary>Audit trail — <N> finding(s) dropped by the engine's scope filter</summary>

| Drop reason | Count |
|---|---|
| File out of scope | DROPPED_COUNTS.out_of_scope |
| Line pre-existing (outside ±15 of any changed line) | DROPPED_COUNTS.pre_existing |
| Markdown documentation example | DROPPED_COUNTS.doc_example |

If the filter dropped something it shouldn't have, the kept-finding list above will need a manual top-up — see the dropped JSON in `/tmp/pr-review-gh-<PR_NUMBER>-dropped.json` for the full details (file/line/description/distance_to_nearest_changed_line).

</details>

_Automated parallel review. Re-runs on new commits if `--watch` is active._
```

The `<details>` audit block is rendered only when `DROPPED_FINDINGS` is non-empty; omit the entire block when zero findings were dropped (no noise on clean diffs). Write `DROPPED_FINDINGS` to `/tmp/pr-review-gh-<PR_NUMBER>-dropped.json` so the user can inspect locally — do NOT post the full dropped list inline (most are noise).

If `<FAILED_AGENTS>` is non-zero, prepend `> WARNING: <FAILED_AGENTS> of <TOTAL_AGENTS_LAUNCHED> agents failed (<names>) — review may be incomplete.` to the body.

If zero findings AND zero failures, submit with empty `comments[]` and a body saying `Sentinel: REVIEW_CLEAN — no issues found in this review.`. If zero findings BUT non-zero failures, the body must say `Sentinel: REVIEW_INCOMPLETE — <FAILED_AGENTS> of <TOTAL_AGENTS_LAUNCHED> agents failed (<names>); no findings does NOT mean clean.`

### Submit

```bash
gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews \
  --method POST \
  --input "$REVIEW_FILE"
```

Atomic — no partial reviews. Clean up: `rm -f "$REVIEW_FILE"`.

Fallback on failure (permissions, line numbers out of range): post a single PR-level comment via `gh api repos/<OWNER>/<REPO>/issues/<PR_NUMBER>/comments`.

## Step 8: Report

Print the sentinel:

```
Sentinel: REVIEW_DONE_PR — PR #<PR_NUMBER>, <N> findings, mode=LocalPR, commit=<HEAD_SHA_SHORT>
```

If `--watch` was NOT passed, the skill is complete here. If `--watch` WAS passed, proceed to Step 9.

## Step 9: Schedule the watcher (only with --watch)

Use `CronCreate` to schedule a recurring job every 2 minutes (`*/2 * * * *`, recurring: true).

### Placeholder discipline (CRITICAL)

Two kinds of placeholders in the watcher prompt:

- **CronCreate-time placeholders** (substitute BEFORE CronCreate): `<PR_NUMBER>`, `<OWNER>`, `<REPO>`, `<REPO_PATH>`, `<HEAD_BRANCH>`, `<BASE_BRANCH>`, `<BOT_LOGIN>`. These seven are static.
- **Cycle-derived** (do NOT substitute): `${CYCLE_HEAD_SHA}`, `${CYCLE_HEAD_SHA_SHORT}`, `${CYCLE_PR_STATE}`, `${CYCLE_LAST_REVIEWED_SHA}`, `${CYCLE_FAILED_AGENTS}`, `${CYCLE_LAST_REVIEWED_RAW}`. Computed inside each cycle.

Pre-flight before CronCreate: refuse empty/whitespace-only prompt; refuse if any of the seven static placeholders remain unsubstituted.

```bash
if [ -z "${ASSEMBLED_PROMPT//[[:space:]]/}" ]; then
  echo "Sentinel: WATCH_REJECTED — assembled prompt is empty or whitespace-only." >&2
  exit 1
fi
ALLOWLIST_REGEX='<(PR_NUMBER|OWNER|REPO|REPO_PATH|HEAD_BRANCH|BASE_BRANCH|BOT_LOGIN)>'
if printf '%s' "$ASSEMBLED_PROMPT" | grep -Eq "$ALLOWLIST_REGEX"; then
  echo "Sentinel: WATCH_REJECTED — CronCreate-time placeholder still present." >&2
  exit 1
fi
```

### Watcher prompt

```text
You are the PR review watcher for PR #<PR_NUMBER> in <OWNER>/<REPO>.
Repo path: <REPO_PATH>
Head branch: <HEAD_BRANCH>
Base branch: <BASE_BRANCH>
Bot login: <BOT_LOGIN>

This is a RECURRING cron job. Each run is one check cycle. After completing a cycle, simply end your response — the cron scheduler will invoke you again in 2 minutes.

Every shell command below must be checked for non-zero exit. On ANY non-zero exit, say "Sentinel: WATCH_TRANSIENT_ERROR — step <N> (<command>): <stderr>" and end this cycle.

Note on shell syntax: `set CYCLE_X = ...` is pseudocode for `CYCLE_X=$(cmd)` (bare LHS — bash assignment never uses `${VAR}=...`). The `${CYCLE_*}` form is for reading.

CYCLE START:

1. FETCH AND CHECK STATE:
   Run: cd <REPO_PATH> && git fetch origin
   set CYCLE_HEAD_SHA = `git rev-parse origin/<HEAD_BRANCH>` — abort if empty.
   set CYCLE_PR_STATE = `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json state --jq '.state'` — abort if gh fails or returns whitespace-only.
   If ${CYCLE_PR_STATE} is not "OPEN": say "Sentinel: WATCH_PR_CLOSED — PR #<PR_NUMBER> state=${CYCLE_PR_STATE}, watcher exiting." and end.
   set CYCLE_HEAD_SHA_SHORT = first 7 chars of ${CYCLE_HEAD_SHA}.

2. GET LAST REVIEWED SHA. Use --arg login binding:
   set CYCLE_LAST_REVIEWED_RAW = `gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews?per_page=100`
   If gh exit code != 0: abort cycle with WATCH_TRANSIENT_ERROR (do NOT fall through to "review everything").
   set CYCLE_LAST_REVIEWED_SHA = `printf '%s' "${CYCLE_LAST_REVIEWED_RAW}" | jq --arg login "<BOT_LOGIN>" -r '[.[] | select(.user.login == $login or ((.body // "") | test("Parallel PR Review|Code Review Summary|local:pr-review-gh|pr-review-gh")))] | sort_by(.submitted_at) | last | .commit_id // ""'`
   If gh exit was zero AND ${CYCLE_LAST_REVIEWED_SHA} is empty: proceed with empty value (review everything on first sighting).

3. COMPARE SHA:
   If ${CYCLE_HEAD_SHA} == ${CYCLE_LAST_REVIEWED_SHA}: say "Sentinel: WATCH_REVIEW_CLEAN — PR #<PR_NUMBER> still at ${CYCLE_HEAD_SHA_SHORT}, no new commits since last review." and end this cycle.

4. NEW COMMIT DETECTED:
   Say "New commit detected on PR #<PR_NUMBER>: ${CYCLE_HEAD_SHA}. Running full review..."

5. **Read `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/SKILL.md` and follow Steps 3–6 there**, with:
   - <DIFF_SOURCE> = pr
   - <HEAD_REF> = origin/<HEAD_BRANCH>
   - <BASE_BRANCH> = <BASE_BRANCH>
   - re-discover PROJECT_CONTEXT and conditional flags per cycle (do NOT cache from earlier cycles).

   The base produces: <FINDINGS>, ${CYCLE_FAILED_AGENTS}, <COUNTS>, <TOTAL_AGENTS_LAUNCHED>.

6. POST REVIEW to GitHub as a single atomic call:
   Build a JSON file at /tmp/local:pr-review-gh-<PR_NUMBER>-cycle.json with commit_id=${CYCLE_HEAD_SHA} (NOT a CronCreate-time SHA), event="COMMENT", body (summary table), and comments[] array.
   If ${CYCLE_FAILED_AGENTS} > 0, prepend "> WARNING: ${CYCLE_FAILED_AGENTS} of <TOTAL_AGENTS_LAUNCHED> agents failed (<names>) — review may be incomplete." to the body.
   Run: gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews --method POST --input /tmp/local:pr-review-gh-<PR_NUMBER>-cycle.json — abort cycle if non-zero exit.
   Clean up: rm -f /tmp/local:pr-review-gh-<PR_NUMBER>-cycle.json

7. Say "Sentinel: WATCH_REVIEW_DONE — PR #<PR_NUMBER> commit ${CYCLE_HEAD_SHA_SHORT}: <N> findings (X critical, Y high, Z medium, W low)."

CYCLE END — the cron scheduler will run this again in 2 minutes.
```

After CronCreate returns the job ID:

1. Report the job ID to the user.
2. Tell them they can cancel with `CronDelete` using that ID.
3. Note that the watcher auto-expires after 3 days.
4. Only THEN is the skill complete.

## Error handling

- If the PR doesn't exist: tell the user and stop.
- If posting the review fails: fall back to a single PR-level comment (`gh api repos/<OWNER>/<REPO>/issues/<PR_NUMBER>/comments`).
- If `CronCreate` is not available: skip continuous monitoring, inform the user that `--watch` requires `CronCreate`.

## Notes

- **`COMMENT` event only** — never auto-approve or request changes. The user reviews findings and decides.
- **`--watch` semantics**: 2-minute cron, self-contained per cycle (no CronCreate-time SHA leakage); watcher cycles re-discover project context AND conditional flags per cycle so newly-added React/Web3/Tailwind code triggers the right agents on subsequent runs.
- **Pairs with `/local:pr-fix`**: this skill posts findings; `/local:pr-fix` applies them. With both using `--watch`, they form a fully autonomous review-fix loop.

## Sentinel grammar

| Sentinel | Owning step | Trailer grammar |
|---|---|---|
| `REVIEW_CLEAN` | Step 7 | `— no issues found in this review.` |
| `REVIEW_INCOMPLETE` | Step 7 | `— <FAILED_AGENTS> of <TOTAL_AGENTS_LAUNCHED> agents failed (<names>); no findings does NOT mean clean.` |
| `REVIEW_DONE_PR` | Step 8 | `— PR #<PR_NUMBER>, <N> findings, mode=LocalPR, commit=<HEAD_SHA_SHORT>` |
| `WATCH_REJECTED` | Step 9 pre-flight | `— <reason>` (empty/whitespace prompt OR un-substituted CronCreate-time placeholder) |
| `WATCH_TRANSIENT_ERROR` | Step 9 watcher (any cycle command) | `— step <N> (<command>): <stderr>` |
| `WATCH_PR_CLOSED` | Step 9 watcher Step 1 | `— PR #<PR_NUMBER> state=${CYCLE_PR_STATE}, watcher exiting.` |
| `WATCH_REVIEW_CLEAN` | Step 9 watcher Step 3 | `— PR #<PR_NUMBER> still at ${CYCLE_HEAD_SHA_SHORT}, no new commits since last review.` |
| `WATCH_REVIEW_DONE` | Step 9 watcher Step 7 | `— PR #<PR_NUMBER> commit ${CYCLE_HEAD_SHA_SHORT}: <N> findings (X critical, Y high, Z medium, W low).` |
