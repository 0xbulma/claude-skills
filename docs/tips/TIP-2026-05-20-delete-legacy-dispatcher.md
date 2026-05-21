# TIP-2026-05-20: Delete legacy dispatcher and personas/ (Phase 6)

| Field              | Value                                                                          |
| ------------------ | ------------------------------------------------------------------------------ |
| **Status**         | Shipped                                                                        |
| **Date**           | 2026-05-20                                                                     |
| **Author**         | @0xbulma                                                                       |
| **Related TIB(s)** | [TIB-2026-05-20-pr-review-engine-skill](../tibs/TIB-2026-05-20-pr-review-engine-skill.md) |
| **Sibling TIP(s)** | TIP-2026-05-20-engine-skill-and-persona-migration, TIP-2026-05-20-consumer-migration, TIP-2026-05-20-persona-refinement |
| **Scope**          | Repo-wide                                                                      |

## Context

Seeded from TIB-2026-05-20-pr-review-engine-skill, Phase 6: with all consumers
migrated, `plugins/local/lib/pr-review-base.md` and any remaining
`plugins/local/personas/` content are dead code. Delete them, update root docs.

## Goals

- `plugins/local/lib/` is empty or deleted.
- `plugins/local/personas/` is empty or deleted.
- `CLAUDE.md`, `README.md`, `plugins/local/README.md`, and `test/plugin.bats`
  reflect the new structure.
- Mental-model diagram in `CLAUDE.md` is updated.

## Non-Goals

- Splitting combo personas. That's TIP-D.

## Files to Modify

### Deleted

- `plugins/local/lib/pr-review-base.md` (assuming TIP-B has migrated all consumers)
- `plugins/local/lib/` (if empty after the delete)
- `plugins/local/personas/` (already empty after TIP-A; remove the directory)

### Modified

- `CLAUDE.md` — update Mental Model diagram and persona-contract section
- `README.md` — update plugin layout description if it lists `personas/` / `lib/`
- `plugins/local/README.md` — same
- `test/plugin.bats` — remove tests that reference `lib/` or top-level `personas/`

## Implementation Steps

### Phase 6 — Delete legacy

- [ ] `grep -rn 'lib/pr-review-base\|plugins/local/personas\|\${CLAUDE_PLUGIN_ROOT}/personas\|\${CLAUDE_PLUGIN_ROOT}/lib' plugins/ test/ '*.md'` should show no production references. Documentation references in TIBs/TIPs are acceptable.
- [ ] Delete `plugins/local/lib/pr-review-base.md` and the `lib/` dir if empty.
- [ ] Delete `plugins/local/personas/` if empty.
- [ ] Update `CLAUDE.md` Mental Model: replace `personas/*.md` and `lib/pr-review-base.md` lines with the new `skills/pr-review-engine/{SKILL.md,agents/*.md,references/*.md}` structure.
- [ ] Update `CLAUDE.md` Persona contract section to point at `skills/pr-review-engine/agents/` instead of `plugins/local/personas/`.
- [ ] Update `test/plugin.bats`: remove the `~/.claude/skills/` path-leak check for `$PLUGIN_DIR/lib`; remove the `persona inventory is exactly 11 files` test (or rework to count files under `pr-review-engine/agents/`).

## Block validation

- [ ] `find plugins/local/lib plugins/local/personas 2>/dev/null` returns nothing or "No such file or directory".
- [ ] `grep -rn 'lib/pr-review-base\|plugins/local/personas' plugins/` returns no hits.
- [ ] `grep -rn 'lib/pr-review-base\|plugins/local/personas' CLAUDE.md README.md plugins/local/README.md` returns no hits.

## Verification Checklist

- structural greps above
- bats: not runnable in sandbox; rely on visual inspection of `test/plugin.bats` for consistency
