# local

Ten user-invokable slash-command skills + one engine skill (`pr-review-engine`, invoked by other skills, not directly).

**PR navigation / review / fix** (review side delegates to the shared `pr-review-engine` skill + its 11-agent library)

- **`/local:pr-switch <pr-url-or-num>`** — switch the local checkout to a PR's head branch. Accepts a full GitHub PR URL, `owner/repo#num` shorthand, or a bare number. Refuses cross-repo URLs; resolves a dirty tree interactively (stash/commit/discard/abort).
- **`/local:pr-review-local`** — pre-PR review on the local branch (committed + uncommitted). Terminal-only output. `--fix` applies mechanical fixes.
- **`/local:pr-review-gh <PR>`** — review an open GitHub PR; posts findings as a `COMMENT` review (never auto-approves). `--watch` re-reviews on every new commit.
- **`/local:pr-fix <PR>`** — read unresolved review comments, classify, apply confidence-gated fixes, push, reply, resolve. `--watch` runs a cron-driven fix loop.

**PR / workflow authoring** (repo-agnostic; no persona library)

- **`/local:pr-create`** — open a draft PR from the current diff. Branch, title, body, and label derived without asking.
- **`/local:extract-plan <doc> [project]`** — convert a TIB / ADR / RFC into a Linear project plan with milestones and dependency-aware issues.
- **`/local:tib-create <title>`** — scaffold a new TIB markdown file from the template; pre-fills date, author, and CalVer ID.
- **`/local:tip-create <title> [--tib <path>]…`** — scaffold a TIP (Technical Implementation Plan): the mutable, concrete companion to a TIB. Optionally seeded from one or more TIBs; auto-maintains `Sibling TIP(s)` back-links across TIPs that share a parent TIB.
- **`/local:tib-ship <tib-path>`** — yolo execute a TIB end-to-end: scaffold TIPs, branch, implement, then `review → fix → re-review` until clean (max 5 iterations). Runs the `runtime-validation` persona if UI surfaces changed. Stops with a ready-to-push branch; the user pushes and opens the PR manually.

**Utility**

- **`/local:setup`** — manually install the 18 rubric skills used by the conditional review personas. Same script also runs in the background on every Claude Code session start.

The PR review/fix skills delegate Steps 3–6 to `skills/pr-review-engine/SKILL.md`, which walks `skills/pr-review-engine/agents/*.md` and dispatches one sub-agent per matching file in parallel. Baseline agents always fire; conditional agents fire when their trigger flag matches the diff (Web3, React/Next, Tailwind/styling, CI/release). Shared rubric content lives in `skills/pr-review-engine/references/` and is loaded on demand by agents that cite it.

## Prerequisites

- `gh` CLI authenticated (`gh auth status`) — for the GitHub skills.
- `git` ≥ 2.30.

Three Anthropic marketplace skills are *optional* — when installed, the React/Next and Tailwind conditional personas use them as rubric. When absent, the personas fall back to their built-in rubric:

- `vercel-react-best-practices`
- `vercel-composition-patterns`
- `tailwind-design-system`

## Install (as a marketplace plugin)

```
/plugin marketplace add 0xbulma/claude-skills
/plugin install local@claude-skills
```

## Local development

```bash
claude --plugin-dir ./plugins/local
```

Inside Claude Code, `/reload-plugins` picks up edits without restart.

See the repo-level `CLAUDE.md` for the full mental model.
