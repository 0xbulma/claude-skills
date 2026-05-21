# TIB-2026-05-20: Consolidate PR-review dispatcher and personas into a single Anthropic-pattern skill

| Field                | Value                                                                  |
| -------------------- | ---------------------------------------------------------------------- |
| **Status**           | Proposed                                                               |
| **Date**             | 2026-05-20                                                             |
| **Author**           | @0xbulma                                                               |
| **Scope**            | Repo-wide (`plugins/local/{lib,personas}/` + four consumer skills)     |
| **Companion TIP(s)** | [TIP-2026-05-20-engine-skill-and-persona-migration](../tips/TIP-2026-05-20-engine-skill-and-persona-migration.md), [TIP-2026-05-20-consumer-migration](../tips/TIP-2026-05-20-consumer-migration.md), [TIP-2026-05-20-delete-legacy-dispatcher](../tips/TIP-2026-05-20-delete-legacy-dispatcher.md), [TIP-2026-05-20-persona-refinement](../tips/TIP-2026-05-20-persona-refinement.md) |

---

## Context

### What exists today

The PR review subsystem is spread across three top-level locations under `plugins/local/`:

```
plugins/local/
├── lib/
│   └── pr-review-base.md            219 lines. Not a skill. A Markdown blob that
│                                    skills "include" by reading it. Contains the
│                                    dispatch logic at Step 5 that walks personas/
│                                    and fans out one sub-agent per matching file.
├── personas/                        11 flat files, 967 lines total (avg 88, max 132).
│   ├── ai-sdk-best-practices.md     Each declares a `trigger:` and is consumed by
│   ├── ci-release-security.md         the dispatcher.
│   ├── code-quality.md
│   ├── code-simplifier-performance.md
│   ├── documentation.md
│   ├── react-next-best-practices.md
│   ├── runtime-validation.md
│   ├── silent-failure-hunter.md
│   ├── test-coverage.md
│   ├── ui-styling-accessibility.md
│   └── web3-security.md
└── skills/
    ├── pr-review-gh/SKILL.md        250 lines. Steps 3–6 delegate to lib/pr-review-base.md.
    ├── pr-review-local/SKILL.md     224 lines. Same.
    ├── pr-fix/SKILL.md              830 lines. Does NOT use the dispatcher; hardcodes
    │                                  three persona filenames at Step 6a.5 as fix rubrics.
    └── tib-ship/SKILL.md            204 lines. Reads lib/pr-review-base.md.
```

### Three problems

1. **`lib/` and `personas/` are orphan directories.** Neither is a "skill" in the
   Agent Skills spec sense — they're a parallel mini-framework grafted on. The four
   consumer skills each duplicate the wiring ("read `lib/pr-review-base.md`, walk
   `personas/`"). `pr-fix` doesn't even do the same wiring; it reimplements parts
   of the dispatcher inline.

2. **Persona content overlaps and duplicates.** Audit findings:
   - **Four combo personas** fuse distinct concerns:
     - `ci-release-security.md` — CI workflow security + release integrity + dep hygiene
     - `code-simplifier-performance.md` — its header reads "Two concerns sharing a persona"
     - `ui-styling-accessibility.md` — Tailwind/tokens + a11y
     - `documentation.md` — self-described "Three concerns, one persona"
   - **Hard finding-level overlap.** `code-quality` and `code-simplifier-performance`
     both claim "duplicated logic / deep nesting" as in-scope. Two parallel agents
     reliably file the same finding.
   - **Duplicate marketplace-rubric loads.** The `building-components` skill is
     referenced as a canonical rule by both `react-next-best-practices` AND
     `ui-styling-accessibility`. `ai-elements` + `streamdown` are referenced by both
     `ai-sdk-best-practices` AND `ui-styling-accessibility`. The same external rubric
     is fetched and read in full by two parallel agents on the same diff (~4–6K
     tokens of waste per review on stacks that hit both).

3. **`pr-fix` is coupled to specific persona filenames.** Step 6a.5 hardcodes
   `web3-security.md`, `ci-release-security.md`, and `documentation.md` inline. Any
   rename or split of those files requires editing `pr-fix/SKILL.md`. This blocks
   the persona restructure.

### Anthropic conventions that constrain the solution shape

The official `anthropics/skills` repository (`https://github.com/anthropics/skills`)
follows four conventions that this TIB treats as binding:

| Tempting design move | What Anthropic actually does |
| --- | --- |
| Folder grouping by category (e.g. `baseline/`/`stack/`/`workflow/`) | **Flat.** 17 skills sit as siblings under `skills/`; no taxonomy directories. |
| Top-level `_shared/` / `common/` / `lib/` cross-cutting dir | **None.** No such directory exists. Each skill is hermetic. |
| Frontmatter manifests (e.g. `owns:`/`defers:`/`fix-rubric:`) | **Off-spec.** The Agent Skills spec mandates only `name` + `description`. `pdf/pptx/docx` add `license` informally. The harness ignores other keys. |
| Closed trigger flag enum (`react`, `web3`, …) | **Prose.** Triggers are free-text in the `description` field ("use when …"); they are not a typed dispatch layer. |

Anthropic's `skill-creator` skill is the **only fan-out pattern** in their repo:

```
anthropics/skills/skills/skill-creator/
├── SKILL.md                       ← dispatcher (spawns analyzer/comparator/grader)
├── agents/
│   ├── analyzer.md
│   ├── comparator.md
│   └── grader.md
└── references/
    └── schemas.md
```

This is the shape this TIB adopts.

## Goals / Non-Goals

**Goals**

- Eliminate the orphan `lib/` and `personas/` directories. All persona content lives
  inside a real skill, following Anthropic's `skill-creator` shape.
- Sharpen persona boundaries by splitting the four combo files so each agent has
  exactly one concern.
- Deduplicate marketplace-rubric loads. A rubric referenced by N personas is loaded
  by at most N sub-agents that actually fire on the diff, never by the dispatcher
  itself.
- Decouple `pr-fix` from specific persona filenames. `pr-fix` invokes the dispatcher
  the same way `pr-review-*` does.
- Stay on-spec. Frontmatter remains `name` + `description` (+ `license` if applicable).
  Trigger logic is description-prose, not a typed enum.
- Keep the dispatcher SKILL.md under the 500-line guideline that
  `anthropics/skills/skills/skill-creator/SKILL.md` enforces.

**Non-Goals**

- Rewriting the substantive review rules inside each persona. This TIB moves and
  splits content; it does not change what gets flagged.
- Adding new stack coverage (Vue, Svelte, Rust). Existing coverage is preserved.
- Resolving the `pr-fix/SKILL.md` length problem (830 lines, over the 500 guideline).
  This TIB shrinks it by ~120 lines via decoupling but does not refactor the rest.
  Tracked as a follow-up.
- Touching the marketplace rubrics themselves (`building-components`, `ai-elements`,
  `streamdown`). They are external skills consumed by personas; how they are loaded
  changes, what they say does not.

## Current Solution

The dispatcher pseudocode today (`lib/pr-review-base.md` Steps 3–6, paraphrased):

```
3. Compute file-pattern flags from diff: <HAS_REACT>, <HAS_WEB3>, <HAS_AI_SDK>, …
4. Run a series of always-on baseline checks (lint/typecheck delta).
5. For each file in personas/*.md:
     parse its `trigger:` frontmatter against the flag set
     if it matches:
       spawn a parallel general-purpose Agent
       hand it the persona file contents to follow
6. Collect findings, deduplicate, format report.
```

Consumer skills (`pr-review-gh`, `pr-review-local`, `tib-ship`) inline a "read
`lib/pr-review-base.md` and follow Steps 3–6" instruction. `pr-fix` does not; it
re-implements Steps 3–6 with its own Step 6a.5 that hardcodes three persona
filenames as fix rubrics.

## Proposed Solution

Create a new skill, `pr-review-engine`, that absorbs the dispatcher and personas
into a single hermetic unit mirroring `anthropics/skills/skills/skill-creator/`.

### Target layout

```
plugins/local/skills/pr-review-engine/
├── SKILL.md                         ← ~200 lines. The dispatcher. Was lib/pr-review-base.md.
│                                       Frontmatter: name + description only.
├── agents/                          ← persona files. 15 files after splits.
│   ├── correctness.md               ← was: code-quality.md
│   ├── simplification.md            ← was: ½ of code-simplifier-performance.md
│   ├── performance.md               ← was: ½ of code-simplifier-performance.md
│   ├── error-handling.md            ← was: silent-failure-hunter.md
│   ├── tests.md                     ← was: test-coverage.md
│   ├── docs.md                      ← was: documentation.md
│   ├── react-next.md                ← was: react-next-best-practices.md
│   ├── ai-sdk.md                    ← was: ai-sdk-best-practices.md
│   ├── web3.md                      ← was: web3-security.md
│   ├── styling.md                   ← was: ½ of ui-styling-accessibility.md
│   ├── accessibility.md             ← was: ½ of ui-styling-accessibility.md
│   ├── ci-security.md               ← was: ⅓ of ci-release-security.md
│   ├── release-integrity.md         ← was: ⅓ of ci-release-security.md
│   ├── dependencies.md              ← was: ⅓ of ci-release-security.md
│   └── runtime-validation.md        ← was: runtime-validation.md (unchanged)
└── references/                      ← shared rubrics. Loaded only when an agent's
    │                                   prose says "Cross-check references/X.md".
    ├── secrets.md                   ← single owner for "did this PR add a credential?"
    ├── injection.md                 ← XSS, dangerouslySetInnerHTML, eval/exec
    ├── effect-cleanup.md            ← intervals, listeners, AbortController
    └── marketplace-rubrics.md       ← building-components / ai-elements / streamdown,
                                        referenced once per persona that needs them
```

**Deleted entirely:** `plugins/local/lib/` and `plugins/local/personas/`.

### Dispatcher (`pr-review-engine/SKILL.md`) shape

Frontmatter (Anthropic spec, two fields only):

```yaml
---
name: pr-review-engine
description: Run a parallel multi-lens review of the current diff. Use when another
  skill needs to perform PR review (called by pr-review-gh, pr-review-local, pr-fix,
  tib-ship). Walks agents/, decides which apply via diff path patterns and dep
  markers, fans out one sub-agent per match, collects findings.
---
```

Body, approximate structure (target ~200 lines):

```
## Inputs
The caller provides: a unified diff, optional base ref, optional review mode flag
(review|fix|tib-validate).

## Step 1 — Compute the diff signal set
Walk changed paths and dependency markers. Produce a small dict of signals:
  routes-changed: bool         (.tsx|.jsx under app/|pages/)
  workflows-changed: bool      (.github/workflows/*)
  changesets-changed: bool     (.changeset/*, CHANGELOG.md, package.json#version)
  lockfile-changed: bool       (package-lock.json|pnpm-lock.yaml|yarn.lock)
  npmrc-changed: bool          (.npmrc)
  has-react: bool              (react in deps or *.tsx|*.jsx files)
  has-next: bool               (next in deps or app/|pages/)
  has-ai-sdk: bool             (ai|@ai-sdk/* in deps)
  has-web3: bool               (viem|wagmi|ethers|abi in deps or *.sol)
  has-tailwind: bool           (tailwindcss in deps or *.css with @tailwind)
  has-styling: bool            (tailwind OR *.module.css|stitches|emotion)
  has-ui: bool                 (any of: tsx/jsx, css-modules, *.html)

## Step 2 — Select agents
Baseline agents fire on every review:
  correctness, simplification, performance, error-handling, tests, docs
Stack agents fire on signals:
  react-next      ← has-react OR has-next
  ai-sdk          ← has-ai-sdk
  web3            ← has-web3
  styling         ← has-tailwind OR has-styling
  accessibility   ← has-ui
Workflow agents fire on signals:
  ci-security        ← workflows-changed
  release-integrity  ← changesets-changed OR (tags pushed)
  dependencies       ← lockfile-changed OR npmrc-changed
  runtime-validation ← routes-changed AND mode != fix

## Step 3 — Fan out
For each selected agent: spawn a parallel general-purpose sub-agent with prompt
"Read pr-review-engine/agents/<name>.md and review the attached diff per its
rubric. Cross-check any references/ files it points to. Report findings only
within its `Scope:` section."

## Step 4 — Collect and dedupe
Aggregate findings. Drop near-duplicates (same file + line + topic). Sort by
severity. Return.

## Step 5 — Mode hooks
If mode == fix: only include agents whose body has a `Fix rubric:` section.
If mode == tib-validate: also include the `docs` agent in strict mode.
```

The exact prose lives in SKILL.md; this is the skeleton. Target ≤500 lines per
the Anthropic `skill-creator` rule.

### Agent file shape (`agents/<name>.md`)

Frontmatter remains spec-minimal. The trigger lives in plain prose. Example:

```markdown
---
name: ci-security
description: Review CI workflow files for injection, action pinning, and secret
  exposure. Fires when the diff touches .github/workflows/*.
---

## Scope
- Workflow injection via `${{ github.event.* }}` in `run:` blocks
- Unpinned third-party actions (@main, @master, mutable tags)
- Secrets passed via env where `pull_request_target:` is used

## Out of scope
- Release publishing flow → see agents/release-integrity.md
- Lockfile / dep hygiene → see agents/dependencies.md
- Generic hardcoded secrets in source → cross-check references/secrets.md

## Rubric
…
```

`Scope`, `Out of scope`, and (where applicable) `Fix rubric:` are **prose
section headings, not frontmatter keys**. This stays on-spec and is what
`anthropics/skills/skills/skill-creator/agents/*.md` does today.

### `references/` files

`references/` is the Anthropic pattern from
`anthropics/skills/skills/mcp-builder/reference/`. It holds content that multiple
agents need to cross-check.

Files are loaded **on demand** by sub-agents whose persona prose says
"Cross-check references/X.md". The dispatcher never reads `references/`. This
guarantees a referenced rubric is loaded ≤ N times (where N = number of agents
that hit it on this diff), not 11+ times.

### Consumer skill wiring

Four skills change to invoke the engine:

```
pr-review-gh/SKILL.md
pr-review-local/SKILL.md
tib-ship/SKILL.md
pr-fix/SKILL.md         ← biggest win; Step 6a.5 shrinks from ~120 lines to ~5
```

Each consumer's Steps 3–6 collapses to roughly:

```
3. Compute the diff bundle (existing logic).
4. Invoke pr-review-engine: read its SKILL.md and follow it with this diff and
   mode=review (or mode=fix for pr-fix; mode=tib-validate for tib-ship).
5. Format the engine's findings into this skill's report template.
```

### Migration table (old → new)

| Old file (location)                                     | New file (location)                                       | Action |
| ------------------------------------------------------- | --------------------------------------------------------- | ------ |
| `lib/pr-review-base.md`                                 | `skills/pr-review-engine/SKILL.md`                        | rewrite + add frontmatter |
| `personas/code-quality.md`                              | `skills/pr-review-engine/agents/correctness.md`           | `git mv` + trim |
| `personas/code-simplifier-performance.md`               | `agents/simplification.md` + `agents/performance.md`      | split |
| `personas/silent-failure-hunter.md`                     | `agents/error-handling.md`                                | `git mv` |
| `personas/test-coverage.md`                             | `agents/tests.md`                                         | `git mv` |
| `personas/documentation.md`                             | `agents/docs.md`                                          | `git mv` |
| `personas/react-next-best-practices.md`                 | `agents/react-next.md`                                    | `git mv` |
| `personas/ai-sdk-best-practices.md`                     | `agents/ai-sdk.md`                                        | `git mv` |
| `personas/web3-security.md`                             | `agents/web3.md`                                          | `git mv` |
| `personas/ui-styling-accessibility.md`                  | `agents/styling.md` + `agents/accessibility.md`           | split |
| `personas/ci-release-security.md`                       | `agents/ci-security.md` + `agents/release-integrity.md` + `agents/dependencies.md` | split |
| `personas/runtime-validation.md`                        | `agents/runtime-validation.md`                            | `git mv` |
| (shared rubric text scattered across 3 personas)        | `references/secrets.md`                                   | extract + dedupe |
| (`dangerouslySetInnerHTML` / XSS scattered)             | `references/injection.md`                                 | extract |
| (effect-cleanup text in `react-next` + `silent-failure`)| `references/effect-cleanup.md`                            | extract |
| (`building-components` + `ai-elements` + `streamdown` references duplicated across 3 personas) | `references/marketplace-rubrics.md` | extract once |

15 agent files (was 11). Typical-diff agent count drops because today's combo
personas fan out on any sub-trigger; the split versions fire only on their
specific trigger.

### Implementation Phases

Each phase is independently shippable: tests on `test/` fixture diffs pass at
each phase boundary, no skill is left in a half-migrated state.

- **Phase 1 — Skill skeleton.** Create `skills/pr-review-engine/` with a minimal
  `SKILL.md` (frontmatter + dispatcher prose, copied near-verbatim from
  `lib/pr-review-base.md`), an empty `agents/` directory, and an empty
  `references/` directory. Add `pr-review-engine` to `.claude-plugin` manifest.
  No consumer changes yet. **Validation:** the new skill loads; `lib/` and
  `personas/` are untouched; the existing flow still works.

- **Phase 2 — Move personas as-is into `agents/`.** `git mv` each persona file
  into `pr-review-engine/agents/` with the new name from the migration table.
  No content changes. Update `pr-review-engine/SKILL.md` to walk `agents/`
  instead of the now-empty `personas/`. **Validation:** PR review on a test
  fixture produces the same agent count and same findings as before.

- **Phase 3 — Migrate one consumer skill (`pr-review-gh`).** Rewrite its Steps
  3–6 to delegate to `pr-review-engine` instead of `lib/pr-review-base.md`. Keep
  `lib/pr-review-base.md` in place for the other three consumers.
  **Validation:** `pr-review-gh` runs end-to-end on a test PR; other three
  consumers continue to work via `lib/`.

- **Phase 4 — Migrate `pr-review-local` and `tib-ship`.** Same change as Phase
  3. After this phase, only `pr-fix` still reads `lib/pr-review-base.md`.

- **Phase 5 — Decouple `pr-fix`.** Rewrite `pr-fix` Step 6a.5: instead of
  hardcoding three persona filenames, invoke `pr-review-engine` with `mode=fix`.
  The engine includes only agents whose body has a `Fix rubric:` section.
  **Validation:** `pr-fix` produces the same set of fix suggestions on a test
  fixture as before, sourced from `agents/web3.md`, `agents/ci-security.md`,
  `agents/release-integrity.md`, `agents/dependencies.md`, and `agents/docs.md`.

- **Phase 6 — Delete `lib/pr-review-base.md` and `personas/`.** Both directories
  are now unreferenced. Update `CLAUDE.md` and the root `README.md` to remove
  references. **Validation:** `grep -r "lib/pr-review-base\|personas/" plugins/`
  returns no hits outside this TIB and the new skill's own internal docs.

- **Phase 7 — Split combo personas.** Now that everything routes through the
  engine, split the three remaining combos:
  - `ci-release-security` → `ci-security` + `release-integrity` + `dependencies`
  - `ui-styling-accessibility` → `styling` + `accessibility`
  - `code-simplifier-performance` → `simplification` + `performance`
  Update the dispatcher's Step 2 selection logic to add new trigger signals
  (`workflows-changed`, `changesets-changed`, `lockfile-changed`/`npmrc-changed`,
  `has-tailwind` vs `has-styling`). **Validation:** an old combo fixture diff
  fires fewer agents than before; each agent's scope is narrower.

- **Phase 8 — Extract shared rubrics into `references/`.** Move duplicated rubric
  text out of the agents and into `references/{secrets,injection,effect-cleanup,
  marketplace-rubrics}.md`. Update agent prose to "Cross-check references/X.md"
  where it applies. **Validation:** the same finding text appears in
  `references/` once, agents are shorter, the same set of findings is produced
  per diff.

Phases 1–6 are pure structural migration with no content change risk. Phases 7–8
are content-affecting and should land in separate PRs with explicit fixture
comparisons.

## Considered Alternatives

### Alternative A: Three-tier folders + `_shared/` + frontmatter manifests

Three-tier persona folder layout (`baseline/`/`stack/`/`workflow/`), top-level
`_shared/` for shared rubrics, frontmatter manifests (`owns:`, `defers:`,
`fix-rubric:`), closed trigger flag enum.

**Why rejected:** Violates four Anthropic conventions: flat layout, no
`_shared/`, two-field frontmatter, prose triggers. Manifests would be documentation
pretending to be config (the harness ignores keys outside `name`/`description`/
`license`). Introduces taxonomy that doesn't exist in any reference skill.

### Alternative B: Anthropic-native — `pr-review-engine` skill with `agents/` only, no `references/`

Same as the chosen approach but without `references/`. Shared rubric text gets
duplicated inline in each agent that needs it.

**Why rejected:** Solves problems 1 and 3 (orphan directories, `pr-fix` coupling)
but not problem 2 (rubric duplication, ~4–6K tokens of waste per stack diff).
Anthropic itself uses `references/` (`mcp-builder/reference/`) for this exact
case — content that varies by context and needs to be loaded on demand.

### Alternative C: Pure minimal — split combos, keep flat, change nothing else

Split the four combo personas into ~15 flat files. Add new trigger phrases to
each. No new skill, no folder changes, no `references/`.

**Why rejected:** Leaves the orphan `lib/` + `personas/` directories. Leaves
`pr-fix` coupled to specific persona filenames (worse after the split — six
hardcoded names instead of three). Doesn't deduplicate rubric loads. Smallest
blast radius but smallest payoff; only addresses problem 2 partially.

### Alternative D: Status quo + only the two highest-leverage fixes

Split `ci-release-security` 3-way and add inline "see persona X" cross-references.
Stop.

**Why rejected:** Half-measure. Leaves three other combos, doesn't fix rubric
duplication, doesn't decouple `pr-fix`, doesn't address the orphan-directories
problem.

### Alternative E: Fold persona content directly into each consumer skill

Inline the relevant personas into `pr-review-gh/SKILL.md`, `pr-review-local`,
`pr-fix`, `tib-ship`. Delete `lib/` and `personas/`. Each consumer skill is
self-contained.

**Why rejected:** Massive content duplication across four skills. Any persona
update has to be repeated four times. Pushes consumer skills past the 500-line
guideline immediately. Solves the "orphan directories" problem by trading it for
a worse "four-way duplication" problem.

## Assumptions & Constraints

- The Anthropic plugin loader respects the standard skill layout
  (`<plugin>/skills/<name>/SKILL.md`) and allows `agents/` and `references/` as
  arbitrary sibling directories. Verified by `anthropics/skills/skills/skill-creator`
  shipping with both.
- Skills can invoke other skills by reading their `SKILL.md` and following the
  instructions. This is how `pr-review-gh` consumes `lib/pr-review-base.md` today,
  so the pattern is already proven; we are only changing the target path.
- The 12-signal selection logic in the dispatcher is sufficient for current stack
  coverage. Adding a 13th stack means editing one place: `SKILL.md` Step 1+2.
- No file under `plugins/local/personas/` or `plugins/local/lib/` is referenced by
  any consumer outside the four listed skills. Verified by
  `grep -r "personas/\|lib/pr-review" plugins/`.

## Dependencies

- `plugins/local/lib/pr-review-base.md` — content source for the new
  `pr-review-engine/SKILL.md`.
- `plugins/local/skills/{pr-review-gh,pr-review-local,pr-fix,tib-ship}/SKILL.md`
  — all four consumer skills must be updated.
- `.claude-plugin/` plugin manifest — add `pr-review-engine` to whatever skill
  list is declared there.
- `CLAUDE.md` and `README.md` — root docs reference the persona system and need
  updating in Phase 6.

## Observability

For each phase, dry-run the engine against `test/` fixture PRs and record:

- Number of sub-agents spawned per fixture (should be ≤ today's count on every
  fixture after Phase 7).
- Set of agent names fired per fixture (should match the signal selection logic).
- Combined token cost per review (should drop by the deduplicated
  marketplace-rubric load weight after Phase 8 — target 4–6K tokens saved on
  stacks that hit both `react` and `ui-styling`).
- Time to first finding (should be similar; the structural change does not affect
  per-agent latency).

No production metrics — this is local-dev tooling.

## Security

The restructure does not change what's reviewed, only how it's dispatched. One
small win: extracting `references/secrets.md` into a single canonical owner for
"did this PR add a hardcoded credential?" replaces the current state where the
rule is restated (and slightly inconsistently) in three personas.

## Future Considerations

- **`pr-fix/SKILL.md` length.** Phase 5 removes ~120 lines. The full restructure
  of `pr-fix` (move the 101-line watcher prompt into `pr-fix/watcher-prompt.md`,
  extract the conditional rubric switch into a sibling) remains a separate TIB.
- **`tip-create` description size.** 515 chars, over the 500-char guideline.
  Trivial fix; track in a docs-cleanup PR.
- **Severity ranking across agents.** Today's dispatcher returns findings in
  spawn order. A future TIB could add a `severity:` field to the agents'
  individual reports and let the engine rank globally.
- **Additional stack coverage.** Adding a new stack (Vue, Svelte, Rust) means
  one new `agents/<stack>.md` file and one new signal in the dispatcher. The
  cost stays linear.

## Open Questions

- **Should `references/marketplace-rubrics.md` be one file or one-per-rubric?**
  Anthropic's `mcp-builder/reference/` uses one file per variant
  (`aws.md`/`gcp.md`/`azure.md`). For three rubrics
  (`building-components`/`ai-elements`/`streamdown`) one file is simpler; if it
  grows past ~200 lines, split. Recommend single file initially.
- **Should `pr-review-engine` be in the `.claude-plugin` manifest as user-invocable?**
  Today's `lib/pr-review-base.md` is internal — never directly invoked. The engine
  has the same role: it's called by other skills, not by the user typing a slash
  command. Recommend `disable-model-invocation: true` on the engine's frontmatter
  (precedent: the `setup` skill in this repo uses the same flag).
- **Phase 7 timing.** Splitting combos in Phase 7 changes the agent count per
  diff. Should this land in a separate PR from Phases 1–6 (lower risk, easier
  rollback) or together (one migration, no intermediate state)? Recommend
  separate PR.

## References

- Anthropic's `skill-creator` skill (the `agents/` precedent):
  `https://github.com/anthropics/skills/tree/main/skills/skill-creator`
- Anthropic's `mcp-builder` skill (the `references/` precedent):
  `https://github.com/anthropics/skills/tree/main/skills/mcp-builder`
- Agent Skills spec (canonical):
  `https://agentskills.io/specification`
- Audit reports (in conversation): skill audit (10 skills, top finding: pr-fix at
  831 lines) and persona scope map (11 files, four combos, dispatcher mechanism).
- Current dispatcher: `plugins/local/lib/pr-review-base.md`
- Current coupling point: `plugins/local/skills/pr-fix/SKILL.md` Step 6a.5
