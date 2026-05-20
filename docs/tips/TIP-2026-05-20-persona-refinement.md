# TIP-2026-05-20: Persona refinement — split combos, extract shared rubrics (Phases 7–8)

| Field              | Value                                                                          |
| ------------------ | ------------------------------------------------------------------------------ |
| **Status**         | Shipped (all phases — splits, renames, `references/`, `## Fix rubric` sections, `mode=fix` filter) |
| **Date**           | 2026-05-20                                                                     |
| **Author**         | @0xbulma                                                                       |
| **Related TIB(s)** | [TIB-2026-05-20-pr-review-engine-skill](../tibs/TIB-2026-05-20-pr-review-engine-skill.md) |
| **Sibling TIP(s)** | TIP-2026-05-20-engine-skill-and-persona-migration, TIP-2026-05-20-consumer-migration, TIP-2026-05-20-delete-legacy-dispatcher |
| **Scope**          | Repo-wide                                                                      |

## Context

Seeded from TIB-2026-05-20-pr-review-engine-skill, Phases 7–8. With the
structural migration complete, this TIP refines content: split the four combo
personas into 8 sharper agents, and extract content cross-referenced by 2+
personas into `references/`.

This is the content-affecting phase. It must preserve review semantics: every
finding the old combo files would produce on a fixture diff must still be
produced by the split files. Net file count: 15 agents (was 11).

## Goals

- `ci-release-security.md` → `ci-security.md` + `release-integrity.md` + `dependencies.md`
- `ui-styling-accessibility.md` → `styling.md` + `accessibility.md`
- `code-simplifier-performance.md` → `simplification.md` + `performance.md`
- `documentation.md` retained as a single agent but with `pointer-integrity` content extracted to `references/`
- `code-quality.md` renamed to `correctness.md`; secrets/injection content extracted to `references/`
- `silent-failure-hunter.md` renamed to `error-handling.md`
- `test-coverage.md` renamed to `tests.md`
- `react-next-best-practices.md` renamed to `react-next.md`
- `ai-sdk-best-practices.md` renamed to `ai-sdk.md`
- `web3-security.md` renamed to `web3.md`
- `runtime-validation.md` unchanged
- `references/secrets.md`, `references/injection.md`, `references/effect-cleanup.md`, `references/marketplace-rubrics.md` created
- Dispatcher updated to recognize new trigger signals (`workflows-changed`, `changesets-changed`, `lockfile-changed`, `npmrc-changed`)

## Non-Goals

- Adding new finding types. Splits preserve existing scope.
- Introducing a typed trigger flag enum (the TIB explicitly avoided that).

## Files to Modify

### New Files (in `plugins/local/skills/pr-review-engine/`)

| File                                | Purpose                                                          |
| ----------------------------------- | ---------------------------------------------------------------- |
| `agents/ci-security.md`             | CI workflow injection, action pinning, secret exposure          |
| `agents/release-integrity.md`       | Publish flow, changesets, release-commit signing                |
| `agents/dependencies.md`            | Lockfile drift, `.npmrc` hygiene, typosquats                    |
| `agents/styling.md`                 | Tailwind / tokens / design-system consistency                   |
| `agents/accessibility.md`           | ARIA, keyboard, focus, alt text                                 |
| `agents/simplification.md`          | Duplicated logic, dead branches, over-engineering               |
| `agents/performance.md`             | Barrel imports, memory leaks, N+1, memo                         |
| `references/secrets.md`             | Hardcoded credentials / env / token rubric                      |
| `references/injection.md`           | XSS, `dangerouslySetInnerHTML`, `eval`, command exec            |
| `references/effect-cleanup.md`      | Intervals, listeners, AbortController                           |
| `references/marketplace-rubrics.md` | `building-components`/`ai-elements`/`streamdown` reference list |

### Renamed / Deleted

| Old name                                  | New name                       |
| ----------------------------------------- | ------------------------------ |
| `agents/code-quality.md`                  | `agents/correctness.md`        |
| `agents/silent-failure-hunter.md`         | `agents/error-handling.md`     |
| `agents/test-coverage.md`                 | `agents/tests.md`              |
| `agents/documentation.md`                 | `agents/docs.md`               |
| `agents/react-next-best-practices.md`     | `agents/react-next.md`         |
| `agents/ai-sdk-best-practices.md`         | `agents/ai-sdk.md`             |
| `agents/web3-security.md`                 | `agents/web3.md`               |
| `agents/code-simplifier-performance.md`   | (split, file deleted)          |
| `agents/ui-styling-accessibility.md`      | (split, file deleted)          |
| `agents/ci-release-security.md`           | (split, file deleted)          |

### Modified

- `plugins/local/skills/pr-review-engine/SKILL.md` — add new trigger signals; update agent inventory section
- `CLAUDE.md` — update persona contract example if it references old persona names

## Implementation Steps

### Phase 7 — Split combos

- [ ] `ci-release-security.md` split: read it once; identify the three rubric sections; write three new agent files with `name`, `description`, `version: 0.1.0`, and the appropriate body. Delete the original.
- [ ] `ui-styling-accessibility.md` split: same pattern, two outputs.
- [ ] `code-simplifier-performance.md` split: same pattern, two outputs.
- [ ] Rename the remaining personas per the table above using `git mv`.
- [ ] Update `pr-review-engine/SKILL.md` Step 5 inventory and Step 4 flag detection (add `workflows-changed`, `changesets-changed`, `lockfile-changed`, `npmrc-changed`).

### Phase 8 — Extract shared rubrics

- [ ] Audit each new agent for duplicated rubric text against the four target categories (secrets, injection, effect-cleanup, marketplace-rubrics).
- [ ] Write each `references/<topic>.md` once.
- [ ] Replace the duplicated text in agents with the pointer line: `Cross-check `references/<topic>.md` when this concern applies.`

## Block validation

- [ ] `find plugins/local/skills/pr-review-engine/agents -name '*.md' | wc -l` returns 15.
- [ ] `find plugins/local/skills/pr-review-engine/references -name '*.md' | wc -l` returns 4.
- [ ] No agent file mentions a marketplace rubric (`building-components`, `ai-elements`, `streamdown`, `web-design-guidelines`, `tailwind-design-system`, `next-best-practices`, `vercel-react-best-practices`, `vercel-composition-patterns`) inline; all such references go through `references/marketplace-rubrics.md`.
- [ ] Each `agents/<name>.md` has frontmatter `name`, `description`, `version` (semver).

## Verification Checklist

- structural greps above
- per-finding spot check: pick 3 lines from each pre-split combo and confirm an equivalent line exists in the corresponding new agent
