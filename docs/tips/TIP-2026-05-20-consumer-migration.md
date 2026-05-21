# TIP-2026-05-20: Consumer migration to pr-review-engine (Phases 3–5)

| Field              | Value                                                                          |
| ------------------ | ------------------------------------------------------------------------------ |
| **Status**         | Shipped                                                                        |
| **Date**           | 2026-05-20                                                                     |
| **Author**         | @0xbulma                                                                       |
| **Related TIB(s)** | [TIB-2026-05-20-pr-review-engine-skill](../tibs/TIB-2026-05-20-pr-review-engine-skill.md) |
| **Sibling TIP(s)** | TIP-2026-05-20-engine-skill-and-persona-migration, TIP-2026-05-20-delete-legacy-dispatcher, TIP-2026-05-20-persona-refinement |
| **Scope**          | Repo-wide                                                                      |

## Context

Seeded from TIB-2026-05-20-pr-review-engine-skill: with the engine skill in
place and personas relocated under `agents/`, the four consumer skills can be
switched off `lib/pr-review-base.md` and onto `pr-review-engine`. This TIP
groups Phases 3–5 (consumer migration + `pr-fix` decoupling) because they
follow the same pattern.

## Goals

- `pr-review-gh`, `pr-review-local`, and `tib-ship` invoke the engine instead of
  reading `lib/pr-review-base.md`.
- `pr-fix` Step 6a.5 no longer hardcodes persona filenames; it invokes the
  engine with a `mode=fix` selector.
- No behavioral regression: a review on a test fixture diff produces the same
  set of agents and findings as before.

## Non-Goals

- Deleting `lib/pr-review-base.md`. That's TIP-C.
- Rewriting persona content. That's TIP-D.

## Files to Modify

### Modified Files

| File                                              | Changes                                                              |
| ------------------------------------------------- | -------------------------------------------------------------------- |
| `plugins/local/skills/pr-review-gh/SKILL.md`      | Steps 3–6 delegate to `pr-review-engine/SKILL.md`                    |
| `plugins/local/skills/pr-review-local/SKILL.md`   | Same                                                                 |
| `plugins/local/skills/tib-ship/SKILL.md`          | Same (preserves `<EXCLUDE_AGENTS>` pass-through for runtime-validation) |
| `plugins/local/skills/pr-fix/SKILL.md`            | Step 6a.5 collapses from ~120 lines of hardcoded persona references to a single `mode=fix` engine invocation |

### New Files

None.

## Implementation Steps

### Phase 3 — Migrate `pr-review-gh`

- [ ] Replace the "delegate to `lib/pr-review-base.md`" stanza with "delegate to `skills/pr-review-engine/SKILL.md`."
- [ ] Verify the consumer's Steps 1–2 (resolve branches, head SHA) still hand off the same caller-provided contract (`<OWNER>`, `<REPO>`, `<HEAD_BRANCH>`, `<BASE_BRANCH>`, `<HEAD_SHA>`, `<DIFF_SOURCE>`, `<HEAD_REF>`, `<EXCLUDE_AGENTS>`).

### Phase 4 — Migrate `pr-review-local` and `tib-ship`

- [ ] Same pattern as Phase 3.
- [ ] In `tib-ship`, confirm Step 5's `<EXCLUDE_AGENTS>` mechanism is preserved (used to skip `runtime-validation` in the inner loop).

### Phase 5 — Decouple `pr-fix`

- [ ] Add a `mode` input to the engine's contract: `review` (default), `fix`, `tib-validate`.
- [ ] In the engine, when `mode=fix`, restrict the agent set to those whose body contains a `## Fix rubric` section (prose contract, no frontmatter flag).
- [ ] In `pr-fix/SKILL.md` Step 6a.5, replace the inline persona references (~120 lines for `web3-security`, `ci-release-security`, `documentation`) with: "Invoke the engine with `mode=fix`. Apply each finding's fix suggestion."
- [ ] Add `## Fix rubric` sections to the personas that today serve as fix sources (`web3-security`, `ci-release-security`, `documentation`).

## Block validation

- [ ] `grep -rn 'lib/pr-review-base' plugins/local/skills/pr-review-gh plugins/local/skills/pr-review-local plugins/local/skills/tib-ship plugins/local/skills/pr-fix` returns zero hits.
- [ ] `grep -rn 'personas/' plugins/local/skills/pr-fix` returns zero hits (no hardcoded persona filenames).
- [ ] `wc -l plugins/local/skills/pr-fix/SKILL.md` is at least 100 lines smaller than before.
- [ ] Each migrated consumer still has the same Steps 1–2 callout (the delegation point changes, not the surrounding flow).

## Verification Checklist

- structural greps above
- manual read-through of each migrated SKILL.md confirming the engine handoff is clear
