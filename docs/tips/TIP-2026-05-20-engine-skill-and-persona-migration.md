# TIP-2026-05-20: Engine skill and persona migration (Phases 1–2)

| Field              | Value                                                                          |
| ------------------ | ------------------------------------------------------------------------------ |
| **Status**         | Shipped                                                                        |
| **Date**           | 2026-05-20                                                                     |
| **Author**         | @0xbulma                                                                       |
| **Related TIB(s)** | [TIB-2026-05-20-pr-review-engine-skill](../tibs/TIB-2026-05-20-pr-review-engine-skill.md) |
| **Sibling TIP(s)** | TIP-2026-05-20-consumer-migration, TIP-2026-05-20-delete-legacy-dispatcher, TIP-2026-05-20-persona-refinement |
| **Scope**          | Repo-wide                                                                      |

## Context

Seeded from TIB-2026-05-20-pr-review-engine-skill: today's `plugins/local/lib/`
and `plugins/local/personas/` are orphan directories outside the Anthropic skill
spec. Phases 1–2 create a new skill `plugins/local/skills/pr-review-engine/`
and migrate the 11 personas into its `agents/` subdirectory as-is (no content
changes), mirroring `anthropics/skills/skills/skill-creator/`.

## Goals

- A new skill exists at `plugins/local/skills/pr-review-engine/` with valid
  frontmatter (`name` + `description` + `version`) per the bats test contract.
- All 11 personas live under `pr-review-engine/agents/` with `git mv` preserving
  history.
- The new `SKILL.md` is a faithful port of `lib/pr-review-base.md` (Steps 3–6),
  retitled and adapted to walk `agents/` instead of `personas/`.
- `lib/pr-review-base.md` and the four consumer skills still work end-to-end at
  this phase boundary (legacy path retained until consumers are migrated).

## Non-Goals

- Rewriting any persona body. Splits and content edits land in TIP-D.
- Touching the four consumer skills. Their migration lands in TIP-B.
- Extracting shared rubrics. That lands in TIP-D.

## Files to Modify

### New Files

| File                                                       | Purpose                    |
| ---------------------------------------------------------- | -------------------------- |
| `plugins/local/skills/pr-review-engine/SKILL.md`           | Dispatcher (ex-lib)        |
| `plugins/local/skills/pr-review-engine/agents/*.md`        | 11 personas (`git mv`)     |
| `plugins/local/skills/pr-review-engine/references/.gitkeep` | Placeholder for TIP-D      |

### Modified Files

| File                                | Changes                                                |
| ----------------------------------- | ------------------------------------------------------ |
| `test/plugin.bats`                  | Update skill list (10→11), persona inventory check, leaked-path globs |
| `.claude-plugin/marketplace.json`   | None (the marketplace lists the plugin, not individual skills) |
| `plugins/local/.claude-plugin/plugin.json` | None (plugin manifest does not enumerate skills) |

## Implementation Steps

### Phase 1 — Skill skeleton

- [x] Create `plugins/local/skills/pr-review-engine/{agents,references}/`.
- [x] Author `pr-review-engine/SKILL.md` with `name`, `description`, `version: 0.1.0` frontmatter. Body is a port of `lib/pr-review-base.md` Steps 3–6, but the persona walk now targets `${CLAUDE_PLUGIN_ROOT}/skills/pr-review-engine/agents/*.md`.
- [x] Add `disable-model-invocation: true` to the engine's frontmatter (engine is invoked by other skills, not the user — same pattern as `setup`).

### Phase 2 — Move personas into `agents/`

- [x] `git mv` each `plugins/local/personas/*.md` → `plugins/local/skills/pr-review-engine/agents/<same-name>.md`. No content changes.
- [x] Update `test/plugin.bats`: bump `SKILLS_ALL` from 10 to 11 entries (add `pr-review-engine`); rename `PERSONAS_DIR` test to walk the new path; keep the count at 11 for now.

## Block validation

- [ ] `find plugins/local/skills/pr-review-engine/agents -name '*.md' | wc -l` returns 11.
- [ ] `plugins/local/personas/` is empty (or removed in TIP-C).
- [ ] `grep -rn 'plugins/local/personas\|lib/pr-review-base' plugins/local/skills/pr-review-engine/` returns no hits (the engine references its own `agents/`, not the legacy locations).
- [ ] `plugins/local/lib/pr-review-base.md` still exists (legacy consumers haven't been migrated yet — that's TIP-B).
- [ ] `awk '/^---$/{f=!f;next} f && /^version:/{print}' plugins/local/skills/pr-review-engine/SKILL.md` returns a semver.

## Verification Checklist

- format: n/a (Markdown-only)
- lint: n/a
- typecheck: n/a
- test: `bats test/plugin.bats` would run if `bats` were on PATH. Sandbox does not have it; the structural greps above replace that gate for this PR.
