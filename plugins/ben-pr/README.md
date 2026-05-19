# ben-pr

Three slash-command skills for Claude Code:

- **`/ben-pr:review-local`** — pre-PR review on the local branch (committed + uncommitted). Terminal-only output. `--fix` applies mechanical fixes.
- **`/ben-pr:review-gh <PR>`** — review an open GitHub PR; posts findings as a `COMMENT` review (never auto-approves). `--watch` re-reviews on every new commit.
- **`/ben-pr:fix <PR>`** — read unresolved review comments, classify, apply confidence-gated fixes, push, reply, resolve. `--watch` runs a cron-driven fix loop.

All three skills delegate Steps 3–6 to `lib/ben-pr-review-base.md`, which loops over `personas/*.md` and dispatches one Agent per persona in parallel. Baseline personas always fire; conditional personas fire when their trigger flag matches the diff (Web3, React/Next, Tailwind/styling, CI/release).

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
/plugin install ben-pr@ben-claude-skills
```

## Local development

```bash
claude --plugin-dir ./plugins/ben-pr
```

Inside Claude Code, `/reload-plugins` picks up edits without restart.

See the repo-level `CLAUDE.md` for the full mental model.
