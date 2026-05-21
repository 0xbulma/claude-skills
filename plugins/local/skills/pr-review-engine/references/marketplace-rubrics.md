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

This file is the **agent-side load surface** for the marketplace-skill
inventory. When a review agent needs to know which marketplace skill
backs its rubric, it Reads this file once instead of inferring it from
the dispatcher prose or the human-facing tables.

Parallel inventories still live in `CLAUDE.md`, `README.md`, and
`plugins/local/skills/setup/SKILL.md`. Those serve human readers and
the `setup` skill's install loop. This file serves the agents at run
time. They are not currently deduplicated — collapsing the three
human-facing tables into pointer lines is a future cleanup that's
worth doing once the rename / refinement churn settles. Until then,
the four surfaces must stay in sync: any new marketplace prereq or
agent rename has to land in all four places.

The discovery snippet itself is not deduplicated either — each agent
independently invokes `find ~/.claude -type f -name SKILL.md -path
"*<skill-name>*"` for the marketplace skills it needs. The inline
`find_skill` calls are kept because each agent's rubric narrows the
marketplace skill to a specific surface, and the per-agent calls
execute in parallel anyway when the engine fans out. A future
optimization could have agents Read this file's discovery section
once and use a shared resolved-path map — worth doing if a
marketplace skill ever grows to >50 KB.

The companion topic-specific references (`references/secrets.md`,
`references/injection.md`, `references/effect-cleanup.md`) extract
shared **rubric content** (not just discovery), eliminating cross-agent
inline duplication for those three concerns. Consumer agents
cross-check those files via prose pointer lines instead of restating
the rubric.
