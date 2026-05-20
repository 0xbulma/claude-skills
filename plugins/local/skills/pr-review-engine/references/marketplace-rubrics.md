# Marketplace rubric discovery

Canonical reference for the marketplace skills used as rubric by multiple
agents. Loaded on demand by agents that cite this file in their prose;
the dispatcher never auto-loads this directory.

## Discovery snippet (Bash)

Plugin-installed marketplace skills land in a versioned cache; resolve the path
at run time:

```bash
find_skill() { find ~/.claude -type f -name SKILL.md -path "*$1*" 2>/dev/null | head -1; }
```

If a rubric resolves to a non-empty path, Read the file in full and print
`Loaded conditional skill: <name>`. If empty, log `Marketplace skill not found:
<name> — degrading to persona's built-in rubric below` and continue with the
agent's inline rubric.

## Rubric inventory by agent

The same marketplace skill is referenced by 1–3 review agents. Loading it on
demand from this single reference avoids the dispatcher pulling it N times for
N agents on the same diff.

| Marketplace skill                | Used by                                                       |
| -------------------------------- | ------------------------------------------------------------- |
| `vercel-react-best-practices`    | `react-next`                                   |
| `vercel-composition-patterns`    | `react-next`                                   |
| `vercel-react-native-skills`     | `react-next` (RN files only)                   |
| `next-best-practices`            | `react-next`                                   |
| `next-cache-components`          | `react-next`                                   |
| `building-components`            | `react-next`, `styling`, `accessibility`       |
| `web-design-guidelines`          | `styling`, `accessibility`                                    |
| `tailwind-design-system`         | `styling` (when `<HAS_TAILWIND>`)                             |
| `ai-elements`                    | `ai-sdk`, `styling` (when ai-elements imports) |
| `streamdown`                     | `ai-sdk`, `styling` (when streamdown imports)  |
| `ai-sdk`                         | `ai-sdk`                                       |
| `turborepo`                      | `ci-security` (when turbo.json touched)                       |
| `deploy-to-vercel`               | `release-integrity` (when vercel.json / vercel deploy)        |
| `vercel-cli-with-tokens`         | `release-integrity` (when vercel CLI usage)                   |
| `github-actions-docs`            | `ci-security`                                                 |

## Why this lives in `references/`

When a marketplace rubric is referenced inline by multiple agent prompts, every
agent that loads on the same diff independently fetches the skill file —
duplicate work and duplicate tokens. This file is the single canonical
inventory; agents reference it by name (e.g. "Discover marketplace rubric paths
via Bash. See `references/marketplace-rubrics.md`."). The actual `find_skill`
invocation still happens per-agent at run time, but the inventory of which
agent uses which skill is recorded once here.

Future extension: if multiple agents need to share rubric **content** (not just
the discovery list), add a topic-specific reference (`references/secrets.md`,
`references/injection.md`, etc.) with the canonical rubric and have agents
reference it by name. Not done yet — agents still own their inline rubric — but
this directory is the home for that pattern when it becomes worth it.
