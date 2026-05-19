---
name: setup
version: 1.0.0
description: Install the optional rubric skills that the local conditional personas use as run-time guidance. Use when user says /local:setup, "install local prereqs", or sees a "Marketplace skill not found" warning from a review. Idempotent — safe to re-run.
disable-model-invocation: true
---

# /local:setup — Install Prereq Rubric Skills

Installs the five rubric skills used by the conditional review personas. Skills already present are skipped. Failure on any one skill does not abort the others.

A `SessionStart` hook also runs this in the background on every Claude Code session, so this manual command is only needed when:

- You skipped the SessionStart hook install
- The background install failed (no network at startup)
- You want to verify the install state explicitly

## What gets installed

18 rubric skills (16 Vercel-published, 2 community). Most back a conditional persona; a few are utilities.

| Skill | Source | Used by persona / role |
|---|---|---|
| `vercel-react-best-practices` | `vercel-labs/agent-skills` | `react-next-best-practices` |
| `vercel-composition-patterns` | `vercel-labs/agent-skills` | `react-next-best-practices` |
| `vercel-react-native-skills` | `vercel-labs/agent-skills` | `react-next-best-practices` (only when RN code touched) |
| `next-best-practices` | `vercel-labs/next-skills` | `react-next-best-practices` |
| `next-cache-components` | `vercel-labs/next-skills` | `react-next-best-practices` |
| `building-components` | `vercel/components.build` | `react-next-best-practices` + `ui-styling-accessibility` |
| `web-design-guidelines` | `vercel-labs/agent-skills` | `ui-styling-accessibility` |
| `tailwind-design-system` | `wshobson/agents` | `ui-styling-accessibility` |
| `ai-elements` | `vercel/ai-elements` | `ai-sdk-best-practices` + `ui-styling-accessibility` |
| `streamdown` | `vercel/streamdown` | `ai-sdk-best-practices` + `ui-styling-accessibility` |
| `ai-sdk` | `vercel/ai` | `ai-sdk-best-practices` |
| `turborepo` | `vercel/turborepo` | `ci-release-security` (when turbo.json touched) |
| `deploy-to-vercel` | `vercel-labs/agent-skills` | `ci-release-security` (when vercel.json / deploy touched) |
| `vercel-cli-with-tokens` | `vercel-labs/agent-skills` | `ci-release-security` (when vercel CLI touched) |
| `github-actions-docs` | `xixu-me/skills` | `ci-release-security` |
| `agent-browser` | `vercel-labs/agent-browser` | utility (browser automation, not a review rubric) |
| `find-skills` | `vercel-labs/skills` | utility (skill discovery) |
| `before-and-after` | `vercel-labs/before-and-after` | utility (visual diff screenshots) |

All are installed via `npx skills add` to `~/.claude/skills/<name>/SKILL.md`.

## Run

Run the installer with verbose output so the user sees per-skill status:

```bash
VERBOSE=1 ${CLAUDE_PLUGIN_ROOT}/bin/install-prereqs.sh
```

The script prints one `✓` line per skill (installed or already present), one `✗` line per failure, and a summary at the end.

## Pre-conditions

- `npx` (Node.js) on PATH. If absent, the script logs a warning and exits 0; the conditional personas will fall back to their inline rubric.
- Network access to fetch the skills from GitHub. Offline failure is non-fatal — skills can be retried later.

## After running

The conditional personas auto-discover the installed rubric files at run time via:

```bash
find ~/.claude -type f -name SKILL.md -path "*<skill-name>*" 2>/dev/null | head -1
```

So no further wiring is needed — the next review run picks up the new rubrics automatically.
